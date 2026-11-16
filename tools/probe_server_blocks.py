#!/usr/bin/env python3
"""Ask a running Minecraft server whether the blocks Umbra read are really there.

usage: tools/probe_server_blocks.py <host> <port> <password> <umbra dump> <out.txt>

For each coordinate of a grid, take the block and properties Umbra read out of the save
and put the question to the game itself:

    scoreboard players set probe umbra_probe 0
    execute if block <x> <y> <z> <name>[<props>] run scoreboard players add probe umbra_probe 1
    scoreboard players get probe umbra_probe        -> "probe has 1 [umbra_probe]"

`execute if block` is true only when the block *and every property* match, so a reader
that confuses `oak_log[axis=x]` with `oak_log[axis=y]`, or that reports a block the world
does not have, is denied.

The verdict is read off a scoreboard rather than out of the command's reply because the
reply is not dependable: `... run say UMBRA_YES` came back as an empty string for a
predicate that must have been true (bedrock at the bottom of the world), and an empty
reply cannot be told from a refusal (`say`'s message goes to chat). A number cannot be
misread.

Before the sample is taken, the same predicate is asked about a block that is certainly
*not* there; if that one also scores 1, the oracle answers yes to everything and the whole
comparison is worthless, so the probe stops.

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


def score_of(body):
    """`probe has 1 [umbra_probe]` -> 1; `Can't get value...` -> None."""
    m = re.search(r"has (-?\d+)", body or "")
    return int(m.group(1)) if m else None


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
    rid = 100
    confirmed = denied = errors = 0
    lines = []
    try:
        # This deliberately does NOT forceload. It used to, and that was the bug behind the
        # denials in run 43847395025: forceloading a chunk finishes generating it, so the
        # reader's honest "stone at y=54" was answered by a world that had since grown a
        # cave there. Loading is `tools/compare_with_server.sh`'s job, and it does it
        # *before* the save is read and before the save is proved to have stopped changing.
        # By the time this runs, every coordinate below is already in a loaded chunk; if
        # one is not, that is a finding and the sample says so rather than fixing it.
        rid += 1
        x0, x1 = min(c[0] for c in coords), max(c[0] for c in coords)
        z0, z1 = min(c[2] for c in coords), max(c[2] for c in coords)
        print(f"probe: asking inside {x0}..{x1} {z0}..{z1} without loading anything here")
        rid += 1
        # Creating it twice is an error the server reports; the objective only has to exist.
        print(f"probe: scoreboard: {command(sock, rid, 'scoreboard objectives add umbra_probe dummy')[:100]}")

        def ask(x, y, z, state):
            """1 if the server says `state` is at x y z, 0 if it denies it, None on error."""
            nonlocal rid
            rid += 1
            command(sock, rid, "scoreboard players set probe umbra_probe 0")
            rid += 1
            command(sock, rid,
                    f"execute if block {x} {y} {z} {state} run "
                    f"scoreboard players add probe umbra_probe 1")
            rid += 1
            return score_of(command(sock, rid, "scoreboard players get probe umbra_probe"))

        # A control: ask about a block that is not there. If the oracle says yes to this,
        # it says yes to everything and the sample below would prove nothing.
        cx, cy, cz = coords[0]
        wrong = "minecraft:bedrock" if not dump[(cx, cy, cz)].startswith("minecraft:bedrock") \
            else "minecraft:stone"
        control = ask(cx, cy, cz, wrong)
        print(f"probe: control: {wrong} at {cx} {cy} {cz} scores {control} "
              f"(0 means the oracle can say no)")
        if control != 0:
            print("probe: FAIL the oracle accepts a block that is not there", file=sys.stderr)
            sock.close()
            return 1

        for (x, y, z) in coords:
            state = dump[(x, y, z)]
            value = ask(x, y, z, state)
            if value == 1:
                confirmed += 1
                lines.append(f"{x} {y} {z} {state} ok")
            elif value == 0:
                denied += 1
                # A denial is either a wrong block or a right block in the wrong place.
                # The six neighbours settle which: a reader that shifts a section by one
                # y, or one column by one x, shows up here as the answer moving with it.
                shifted = []
                for (dx, dy, dz) in ((0, -1, 0), (0, 1, 0), (-1, 0, 0), (1, 0, 0),
                                     (0, 0, -1), (0, 0, 1)):
                    if ask(x + dx, y + dy, z + dz, state) == 1:
                        shifted.append(f"{dx:+d}{dy:+d}{dz:+d}")
                mark = ("moved " + ",".join(shifted)) if shifted else "nowhere near"
                lines.append(f"{x} {y} {z} {state} DENIED {mark}")
                if denied <= 6:
                    print(f"probe: the server denied {state} at {x} {y} {z}: {mark}")
            else:
                errors += 1
                if errors <= 3:
                    print(f"probe: no score came back at {x} {y} {z}", file=sys.stderr)

    finally:
        sock.close()

    with open(out, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    print(f"probe: {confirmed} confirmed, {denied} denied, {errors} errors -> {out}")
    if denied and not confirmed:
        print("probe: every coordinate was denied, which is what an unloaded chunk also "
              "looks like; the load in compare_with_server.sh is the first thing to check",
              file=sys.stderr)
    if confirmed < MIN_CONFIRMED:
        print(f"probe: FAIL fewer than {MIN_CONFIRMED} coordinates were confirmed")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
