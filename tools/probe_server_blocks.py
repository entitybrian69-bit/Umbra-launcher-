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


def load_dump(path):
    """`detail x y z minecraft:stone[axis=y]` -> {(x, y, z): 'minecraft:stone[axis=y]'}."""
    out = {}
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) < 5 or parts[0] != "detail":
            continue
        try:
            key = (int(parts[1]), int(parts[2]), int(parts[3]))
        except ValueError:
            continue
        out[key] = parts[4]
    return out


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    host, port, password, dump_path, out = args[0], int(args[1]), args[2], args[3], args[4]

    dump = load_dump(dump_path)
    if not dump:
        print(f"probe: FAIL {dump_path} has no detail lines", file=sys.stderr)
        return 1

    # A grid over the dump, so the sample is spread across the world rather than
    # clustered where the reader happens to have written its first lines.
    xs = sorted({k[0] for k in dump})
    zs = sorted({k[2] for k in dump})
    ys = sorted({k[1] for k in dump})
    want_x = xs[:: max(1, len(xs) // 6)][:6]
    want_z = zs[:: max(1, len(zs) // 6)][:6]
    want_y = ys[:: max(1, len(ys) // 5)][:5]
    coords = [(x, y, z) for x in want_x for z in want_z for y in want_y if (x, y, z) in dump]
    print(f"probe: the dump has {len(dump)} blocks; asking about {len(coords)} of them "
          f"({len(want_x)} x {len(want_z)} x {len(want_y)} grid)")

    sock = connect(host, port, password)
    lines = []
    confirmed = denied = errors = 0
    rid = 100
    try:
        # The chunks have to be loaded for a predicate to answer. The reader only kept
        # chunks that exist in the save, so this is the same region.
        rid += 1
        try:
            a = command(sock, rid, "forceload add -64 -64 80 80")
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
