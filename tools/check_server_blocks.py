#!/usr/bin/env python3
"""Hold Umbra's reader to what the real server said is at a set of coordinates.

usage: tools/check_server_blocks.py <goose-detail.txt> <server-blocks.txt> [--min 10]

The two files come from the same run of the same world:

  * `server-blocks.txt` is the server's own answer, taken over RCON before it stopped
    (`tools/probe_server_blocks.py`);
  * the detail dump is what `goose/worldload.goose` read out of the region files the
    server wrote.

So this compares Umbra's understanding of the save with the game's own statement about
the same coordinates -- the alternative the brief allows when the real client cannot be
run in CI. Block name and every property are compared, exactly: `minecraft:oak_log[axis=x]`
and `minecraft:oak_log[axis=y]` are different blocks in the world, and a reader that
confused them would pass a name-only comparison.

The exit status is 1 on any mismatch, and also when fewer than `--min` coordinates were
compared: an empty comparison is not a pass.
"""
import sys
from collections import defaultdict


def norm(state):
    """`minecraft:stone[axis=y,b=2]` -> ('minecraft:stone', {'axis': 'y', 'b': '2'})`."""
    state = state.strip()
    if "[" not in state:
        return state, {}
    name, rest = state.split("[", 1)
    props = {}
    for pair in rest.rstrip("]").split(","):
        if "=" in pair:
            k, v = pair.split("=", 1)
            props[k.strip()] = v.strip()
    return name, props


def load_detail(path):
    out = {}
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) < 5 or parts[0] != "detail":
            continue
        key = (int(parts[1]), int(parts[2]), int(parts[3]))
        out[key] = parts[4]
    return out


def load_server(path):
    out = {}
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) < 4:
            continue
        key = (int(parts[0]), int(parts[1]), int(parts[2]))
        out[key] = parts[3]
    return out


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    detail_path, server_path = args[0], args[1]
    minimum = 10
    if "--min" in args:
        minimum = int(args[args.index("--min") + 1])

    detail = load_detail(detail_path)
    server = load_server(server_path)
    if not server:
        print(f"FAIL: {server_path} holds no coordinates, so nothing was compared")
        return 1
    if not detail:
        print(f"FAIL: {detail_path} holds no detail lines, so nothing was compared")
        return 1

    agree = 0
    mismatches = []
    missing = []
    for key in sorted(server):
        want = server[key]
        got = detail.get(key)
        if got is None:
            missing.append(key)
            continue
        wn, wp = norm(want)
        gn, gp = norm(got)
        if wn == gn and wp == gp:
            agree += 1
        else:
            mismatches.append((key, want, got))

    checked = len(server)
    print(f"server blocks: {checked} coordinates sampled, {agree} agree, "
          f"{len(mismatches)} differ, {len(missing)} not in Umbra's dump")
    by_block = defaultdict(int)
    for key in server:
        by_block[norm(server[key])[0]] += 1
    top = ", ".join(f"{k} {v}" for k, v in sorted(by_block.items(), key=lambda kv: -kv[1])[:6])
    print(f"server blocks: the sample is {top}")
    for (key, want, got) in mismatches[:10]:
        print(f"server blocks: at {key[0]} {key[1]} {key[2]} the server says {want}, "
              f"Umbra reads {got}")
    for key in missing[:10]:
        print(f"server blocks: at {key[0]} {key[1]} {key[2]} the server says "
              f"{server[key]}, Umbra's dump has no such block")

    if checked < minimum:
        print(f"FAIL: only {checked} coordinates were compared (the minimum is {minimum})")
        return 1
    if mismatches or missing:
        print("FAIL: Umbra's reader disagrees with the server about this world")
        return 1
    print(f"PASS: Umbra reads the same block, with the same properties, at all {checked} "
          f"coordinates the server reported")
    return 0


if __name__ == "__main__":
    sys.exit(main())
