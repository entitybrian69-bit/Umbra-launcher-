#!/usr/bin/env python3
"""Ask a running Minecraft server whether the blocks Umbra read are really there.

usage: tools/probe_server_blocks.py <host> <port> <password> <umbra dump> <out.txt>

For each coordinate of a grid, take the block and properties Umbra read out of the save
and put the question to the game itself:

    execute if block <x> <y> <z> <name>[<props>] run say UMBRA_YES

`execute if block` is true only when the block *and every property* match, so a reader
that confuses `oak_log[axis=x]` with `oak_log[axis=y]`, or that reports a block the world
does not have, is denied. The answer is unambiguous (`UMBRA_YES` present or not), which
matters over RCON: a failed predicate answers with a message whose wording changes
between versions.

Why not `data get block`: in this server version that command answers only for block
entities -- the first version of this tool asked it and got "The target block is not a
block entity" for all 144 coordinates.

Output, one line per coordinate that Umbra had and the server answered:

    x y z minecraft:oak_log[axis=y] ok
    x y z minecraft:stone DENIED

Exit status 1 when fewer than ten coordinates were confirmed, so an empty comparison is
never read as a pass.
"""
import re
import socket
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from rcon import packet, read_packet  # noqa: E402  (same directory, same protocol)

AUTH = 3
COMMAND = 2
MIN_CONFIRMED = 10


def connect(host, port, password):
    sock = socket.create_connection((host, port), timeout=20)
    sock.sendall(packet(1, AUTH, password))
    _rid, kind, _body = read_packet(sock)
    if kind != 2:
        raise RuntimeError("the server refused the rcon password")
    return sock


def command(sock, rid, text):
    sock.sendall(packet(rid, COMMAND, text))
    _rid, _kind, body = read_packet(sock)
    return body


def scan_dump(path):
    """Learn the x and z lines the dump has, without holding every block in memory.

    The dump written for a whole save is hundreds of thousands of lines; the sample only
    needs a handful of columns, so the coordinates are chosen here and their blocks are
    collected in a second pass.
    """
    xs, zs = set(), set()
    lines = 0
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) < 5 or parts[0] != "detail":
            continue
        try:
            xs.add(int(parts[1]))
            zs.add(int(parts[3]))
        except ValueError:
            continue
        lines += 1
    return sorted(xs), sorted(zs), lines


def pick(values, count):
    if not values:
        return []
    if len(values) <= count:
        return values
    step = len(values) / count
    return [values[int(i * step)] for i in range(count)]


def collect(path, want_x, want_z):
    """{(x, y, z): 'name[props]'} for the chosen columns only."""
    sx, sz = set(want_x), set(want_z)
    out = {}
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) < 5 or parts[0] != "detail":
            continue
        try:
            x, y, z = int(parts[1]), int(parts[2]), int(parts[3])
        except ValueError:
            continue
        if x in sx and z in sz:
            out[(x, y, z)] = parts[4]
    return out


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    host, port, password, dump_path, out = args[0], int(args[1]), args[2], args[3], args[4]

    xs, zs, lines = scan_dump(dump_path)
    if lines == 0:
        print(f"probe: FAIL {dump_path} has no detail lines", file=sys.stderr)
        return 1

    want_x = pick(xs, 6)
    want_z = pick(zs, 6)
    dump = collect(dump_path, want_x, want_z)
    ys = pick(sorted({k[1] for k in dump}), 5)
    coords = [(x, y, z) for x in want_x for z in want_z for y in ys if (x, y, z) in dump]
    print(f"probe: the dump has {lines} blocks over {len(xs)} x and {len(zs)} z lines; "
          f"asking about {len(coords)} of them")

    sock = connect(host, port, password)
    lines = []
    confirmed = denied = errors = 0
    rid = 100
    try:
        # The chunks have to be loaded for a predicate to answer. The reader only kept
        # chunks that exist in the save, so this is the same region.
        rid += 1
        try:
            x0, x1 = min(c[0] for c in coords), max(c[0] for c in coords)
            z0, z1 = min(c[2] for c in coords), max(c[2] for c in coords)
            a = command(sock, rid, f"forceload add {x0 - 16} {z0 - 16} {x1 + 16} {z1 + 16}")
            print(f"probe: forceload: {a.strip()[:140]}")
        except (EOFError, OSError) as exc:
            print(f"probe: forceload failed: {exc}", file=sys.stderr)
        time.sleep(2.0)

        for (x, y, z) in coords:
            state = dump[(x, y, z)]
            rid += 1
            try:
                answer = command(sock, rid,
                                 f"execute if block {x} {y} {z} {state} run say UMBRA_YES")
            except (EOFError, OSError) as exc:
                print(f"probe: the connection failed at {x} {y} {z}: {exc}", file=sys.stderr)
                errors += 1
                break
            if "UMBRA_YES" in answer:
                confirmed += 1
                lines.append(f"{x} {y} {z} {state} ok")
            else:
                denied += 1
                lines.append(f"{x} {y} {z} {state} DENIED")
                if denied <= 5:
                    print(f"probe: the server denied {state} at {x} {y} {z}: "
                          f"{answer.strip()[:120]!r}")
    finally:
        sock.close()

    with open(out, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    print(f"probe: {confirmed} confirmed, {denied} denied, {errors} errors -> {out}")
    if confirmed < MIN_CONFIRMED:
        print(f"probe: FAIL fewer than {MIN_CONFIRMED} coordinates were confirmed")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
