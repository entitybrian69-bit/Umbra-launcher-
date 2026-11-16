#!/usr/bin/env python3
"""Downgrade one chunk's Status, so a save looks like one read mid-generation.

usage: tools/downgrade_chunk_status.py <world dir> [status]

A chunk's `Status` says how far its generation got. `minecraft:full` means the world
will never add anything to it; any earlier stage means terrain exists but the carvers,
ores and plants have not run yet. A save that was flushed while the server was still
generating holds chunks in those earlier stages, which is why reading it and then asking
the game about the blocks is comparing two different worlds (run 43847395025).

`goose/worldload.goose` counts such chunks and says so. This tool exists so that claim is
tested rather than trusted: it takes a real save and downgrades the first chunk's status,
leaving every other chunk and the sector table untouched, so the only difference from the
original file is the one word.

Why editing in place is fiddly: a region file's header points at chunks by sector number,
so a rewritten chunk record has to occupy exactly the sectors the old one did. If it does
not, every chunk after it moves and the header lies. This pads the new record back to the
old length, and refuses if the replacement is somehow larger.
"""
import glob
import os
import struct
import sys
import zlib


def region_dir(world):
    for rel in ("dimensions/minecraft/overworld/region", "region"):
        path = os.path.join(world, rel)
        if os.path.isdir(path):
            return path
    return None


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    world = args[0]
    status = args[1] if len(args) > 1 else "minecraft:features"
    new = status.encode()

    directory = region_dir(world)
    if directory is None:
        print(f"FAIL: no region directory under {world}", file=sys.stderr)
        return 1
    files = sorted(glob.glob(os.path.join(directory, "*.mca")))
    if not files:
        print(f"FAIL: no region files in {directory}", file=sys.stderr)
        return 1

    path = files[0]
    raw = open(path, "rb").read()
    head = raw[:8192]
    if len(head) < 8192:
        print(f"FAIL: {path} is shorter than a region header", file=sys.stderr)
        return 1

    # The first chunk slot with an offset, in slot order.
    at = None
    for slot in range(1024):
        word = struct.unpack(">I", head[slot * 4:slot * 4 + 4])[0]
        if word >> 8:
            at = (word >> 8) * 4096
            break
    if at is None:
        print(f"FAIL: {path} points at no chunk", file=sys.stderr)
        return 1

    size = struct.unpack(">I", raw[at:at + 4])[0]
    was = 4 + size
    payload = raw[at + 5:at + 4 + size]
    try:
        nbt = zlib.decompress(payload)
    except zlib.error as exc:
        print(f"FAIL: the first chunk in {path} is not zlib: {exc}", file=sys.stderr)
        return 1

    key = b"\x08\x00\x06Status"
    i = nbt.find(key)
    if i < 0:
        print(f"FAIL: the first chunk in {path} has no Status string", file=sys.stderr)
        return 1
    old_len = struct.unpack(">H", nbt[i + len(key):i + len(key) + 2])[0]
    old = nbt[i + len(key) + 2:i + len(key) + 2 + old_len]
    out = (nbt[:i + len(key)] + struct.pack(">H", len(new)) + new
           + nbt[i + len(key) + 2 + old_len:])

    z = zlib.compress(out, 6)
    rec = struct.pack(">I", len(z) + 1) + b"\x02" + z
    if len(rec) > was:
        print(f"FAIL: the new record is {len(rec)} bytes, the old one {was}; refusing to "
              f"move every chunk behind it", file=sys.stderr)
        return 1
    rec += b"\x00" * (was - len(rec))

    with open(path, "wb") as f:
        f.write(head + rec + raw[at + was:])

    print(f"status: {path} chunk at sector {at // 4096}: "
          f"{old.decode(errors='replace')} -> {status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
