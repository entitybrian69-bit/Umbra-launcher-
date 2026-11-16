#!/usr/bin/env python3
"""Read the server's verdict on the blocks Umbra read, and refuse anything but all yes.

usage: tools/check_server_blocks.py <server-blocks.txt> [--min 10]

`tools/compare_with_server.sh` writes one line per coordinate, in the form

    x y z minecraft:oak_log[axis=y] ok
    x y z minecraft:stone DENIED

The `ok` is the *server's* answer to `execute if block x y z <state>`, taken while it
still had the world in memory. A single DENIED means Umbra's reader told the game
something untrue about the world the game made, and that is a failure, not a note.

The exit status is 1 on any denial, and also when fewer than `--min` coordinates were
confirmed: an empty comparison is not a pass.
"""
import sys


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = args[0]
    minimum = 10
    if "--min" in args:
        minimum = int(args[args.index("--min") + 1])

    confirmed = denied = 0
    denials = []
    states = {}
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) != 5:
            continue
        state, verdict = parts[3], parts[4]
        if verdict == "ok":
            confirmed += 1
            states[state] = states.get(state, 0) + 1
        else:
            denied += 1
            denials.append((parts[0], parts[1], parts[2], state))

    total = confirmed + denied
    print(f"server blocks: {total} coordinates asked, {confirmed} confirmed, {denied} denied")
    if states:
        top = ", ".join(f"{k} {v}" for k, v in sorted(states.items(), key=lambda kv: -kv[1])[:6])
        print(f"server blocks: the confirmed sample is {top}")
    for (x, y, z, state) in denials[:10]:
        print(f"server blocks: the server says {state} is NOT at {x} {y} {z}, "
              f"but Umbra read it there")
    if total == 0:
        print("FAIL: no coordinates were asked; nothing was compared")
        return 1
    if confirmed < minimum:
        print(f"FAIL: only {confirmed} coordinates were confirmed (the minimum is {minimum})")
        return 1
    if denied:
        print("FAIL: Umbra's reader disagrees with the server about this world")
        return 1
    print(f"PASS: the server confirms Umbra's block and properties at all {confirmed} "
          f"coordinates it was asked about")
    return 0


if __name__ == "__main__":
    sys.exit(main())
