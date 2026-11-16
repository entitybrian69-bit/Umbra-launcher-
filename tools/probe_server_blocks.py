#!/usr/bin/env python3
"""Ask a running Minecraft server what block is at a grid of coordinates.

usage: tools/probe_server_blocks.py <host> <port> <password> <out.txt> [--radius 40] [--step 16]

Writes one line per coordinate the server answered:

    x y z minecraft:stone[axis=y]

A position is only readable when its chunk is *loaded*, and a server with no players has
nothing loaded: the first run of this answered "not loaded" for all 144 coordinates. So
the grid is force-loaded first (`forceload add`) and any coordinate that still comes back
unloaded is retried once after a pause.

Why: the second half of gate 6b asks whether Umbra's render matches the real client.
The client cannot be run in CI (no display, no GPU, and the game needs an account), so
the brief allows the alternative it names: compare the *block data* with what the real
server reports. This takes the server's own answers, via RCON, to the world it has just
generated; `tools/check_server_blocks.py` holds Umbra's reader to them afterwards.

Answers that say a position is not loaded are skipped and counted: a coordinate outside
the generated chunks is not evidence either way.
"""
import re
import socket
import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from rcon import packet, read_packet  # noqa: E402  (same directory, same protocol)

AUTH = 3
COMMAND = 2


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


NAME = re.compile(r'Name:"([^"]+)"')
PROPS = re.compile(r"Properties:\{([^}]*)\}")


def parse_state(answer):
    """`... {Name:"minecraft:stone", Properties:{axis:"y"}}` -> `minecraft:stone[axis=y]`."""
    m = NAME.search(answer)
    if not m:
        return None
    name = m.group(1)
    p = PROPS.search(answer)
    if not p:
        return name
    pairs = re.findall(r'([A-Za-z0-9_]+):"([^"]*)"', p.group(1))
    if not pairs:
        return name
    return name + "[" + ",".join(f"{k}={v}" for k, v in sorted(pairs)) + "]"


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    host, port, password, out = args[0], int(args[1]), args[2], args[3]
    radius, step = 40, 16
    if "--radius" in args:
        radius = int(args[args.index("--radius") + 1])
    if "--step" in args:
        step = int(args[args.index("--step") + 1])

    coords = []
    for x in range(-radius, radius + 1, step):
        for z in range(-radius, radius + 1, step):
            for y in (60, 64, 70, 78):
                coords.append((x, y, z))

    sock = connect(host, port, password)
    lines, unloaded, errors = [], 0, 0
    rid = 10
    pending = []
    try:
        # Load the chunks the grid lives in. Without this the server answers "not
        # loaded" for every coordinate, which is a fact about the server (no players,
        # nothing loaded) and not about the world.
        rid += 1
        try:
            answer = command(sock, rid, f"forceload add {-radius - 8} {-radius - 8} "
                                        f"{radius + 8} {radius + 8}")
            print(f"probe: forceload: {answer.strip()[:160]}")
        except (EOFError, OSError) as exc:
            print(f"probe: forceload failed: {exc}", file=sys.stderr)
        time.sleep(2.0)

        for (x, y, z) in coords:
            rid += 1
            try:
                answer = command(sock, rid, f"data get block {x} {y} {z}")
            except (EOFError, OSError) as exc:
                print(f"probe: the connection failed at {x} {y} {z}: {exc}", file=sys.stderr)
                errors += 1
                break
            state = parse_state(answer)
            if state is None:
                low = answer.lower()
                if "not loaded" in low or "outside" in low or "unknown" in low:
                    pending.append((x, y, z))
                    unloaded += 1
                else:
                    errors += 1
                    if errors <= 3:
                        print(f"probe: no block in the answer for {x} {y} {z}: {answer[:200]!r}",
                              file=sys.stderr)
                continue
            lines.append(f"{x} {y} {z} {state}")

        if pending:
            # A chunk that was force-loaded a moment ago may still be on its way; one
            # retry turns "not loaded" into an answer, or confirms it really is outside.
            time.sleep(3.0)
            still = 0
            for (x, y, z) in pending:
                rid += 1
                try:
                    answer = command(sock, rid, f"data get block {x} {y} {z}")
                except (EOFError, OSError):
                    still += 1
                    continue
                state = parse_state(answer)
                if state is None:
                    still += 1
                    continue
                lines.append(f"{x} {y} {z} {state}")
            unloaded = still
    finally:
        sock.close()

    with open(out, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    print(f"probe: {len(lines)} coordinates answered, {unloaded} not loaded, "
          f"{errors} unreadable -> {out}")
    if len(lines) < 10:
        print("probe: FAIL the server answered fewer than ten coordinates")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
