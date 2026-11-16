#!/usr/bin/env python3
"""Rewrite one chunk's Status, so a save looks like one that was read mid-generation.

usage: tools/downgrade_chunk_status.py <world dir> [status] [cx cz]

A chunk's `Status` says how far its generation got. `minecraft:full` means the world will
never add anything to it; any earlier stage means terrain exists but the carvers, ores and
plants have not run yet. A save flushed while the server was still generating holds chunks
in those earlier stages, which is why reading it and then asking the game about the blocks
compares two different worlds (run 43847395025).

`goose/worldload.goose` refuses a read when a chunk inside the detail window is not
`minecraft:full`. This tool exists so that claim is tested rather than trusted: it takes a
real save and downgrades one chunk, so the only difference from the original is that chunk.

Two things make this fiddly, and both bit earlier versions:

  * The status name changes length. `minecraft:full` is 14 bytes and every real earlier
    stage is longer (`minecraft:carvers` 17, `minecraft:biomes` 16, `minecraft:sparse` 16),
    so the record grows and cannot simply be padded back. The chunk is rewritten whole
    instead, and the header's sector table is updated to wherever it now lands. Padding
    only works in the shrinking direction, which is why the writing code below handles both.
  * The chunk to downgrade has to be *inside* the detail window, because that is the only
    place the refusal looks. The first chunk of the first file is the corner of the region
    and typically outside it - that is what made the first version of the CI step fail on a
    real save. Pass `cx cz` to name the chunk by its own coordinates; the default is the
    chunk nearest the origin, which is inside any window that has one.
"""
import glob
import os
import struct
import sys
import zlib

SECTOR = 4096


def region_dir(world):
    for rel in ("dimensions/minecraft/overworld/region", "region"):
        path = os.path.join(world, rel)
        if os.path.isdir(path):
            return path
    return None


def nbt_bytes(raw, at):
    size = struct.unpack(">I", raw[at:at + 4])[0]
    return zlib.decompress(raw[at + 5:at + 4 + size]), size


def chunk_coords(nbt):
    """The chunk's own xPos/zPos, whatever integer tag holds them."""
    out = []
    for name in (b"xPos", b"zPos"):
        found = None
        for kind in (3, 1, 2):
            key = bytes([kind, 0, len(name)]) + name
            i = nbt.find(key)
            if i >= 0:
                found = i
                break
        if found is None:
            return None
        body = nbt[found + len(name) + 3:]
        if kind == 3:
            out.append(struct.unpack(">i", body[:4])[0])
        elif kind == 2:
            out.append(struct.unpack(">h", body[:2])[0])
        else:
            out.append(struct.unpack(">b", body[:1])[0])
    return (out[0], out[1])


def slots(raw):
    """(slot, offset in sectors, length in sectors) for every chunk the header names."""
    head = raw[:8192]
    for slot in range(1024):
        word = struct.unpack(">I", head[slot * 4:slot * 4 + 4])[0]
        if word >> 8:
            yield slot, word >> 8, word & 0xFF


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    world = args[0]
    status = args[1] if len(args) > 1 and args[1] else "minecraft:carvers"
    new = status.encode()
    want = None
    if len(args) >= 4:
        try:
            want = (int(args[2]), int(args[3]))
        except ValueError:
            print("FAIL: cx and cz must be integers", file=sys.stderr)
            return 2

    directory = region_dir(world)
    if directory is None:
        print(f"FAIL: no region directory under {world}", file=sys.stderr)
        return 1
    files = sorted(glob.glob(os.path.join(directory, "*.mca")))
    if not files:
        print(f"FAIL: no region files in {directory}", file=sys.stderr)
        return 1

    # Choose the chunk: the one named, or else the one nearest the origin, which is the
    # one a detail window centred on the origin is certain to contain.
    choice = None
    for path in files:
        raw = open(path, "rb").read()
        if len(raw) < 8192:
            continue
        for slot, offset, length in slots(raw):
            try:
                nbt, _ = nbt_bytes(raw, offset * SECTOR)
            except (struct.error, zlib.error, IndexError):
                continue
            coords = chunk_coords(nbt)
            if coords is None:
                continue
            if want is not None:
                if coords == want:
                    choice = (path, raw, slot, offset, length, nbt, coords)
                    break
            else:
                key = abs(coords[0]) + abs(coords[1])
                if choice is None or key < choice[6]:
                    choice = (path, raw, slot, offset, length, nbt, coords)
        if choice is not None and want is not None:
            break
    if choice is None:
        where = f"at chunk {want[0]},{want[1]}" if want else "in any slot"
        print(f"FAIL: no chunk {where} in {directory}", file=sys.stderr)
        return 1

    path, raw, slot, offset, length, nbt, coords = choice
    key = b"\x08\x00\x06Status"
    i = nbt.find(key)
    if i < 0:
        print(f"FAIL: chunk {coords[0]},{coords[1]} in {path} has no Status string",
              file=sys.stderr)
        return 1
    old_len = struct.unpack(">H", nbt[i + len(key):i + len(key) + 2])[0]
    old = nbt[i + len(key) + 2:i + len(key) + 2 + old_len]
    out = (nbt[:i + len(key)] + struct.pack(">H", len(new)) + new
           + nbt[i + len(key) + 2 + old_len:])

    z = zlib.compress(out, 6)
    record = struct.pack(">I", len(z) + 1) + b"\x02" + z
    need = (len(record) + SECTOR - 1) // SECTOR

    if need <= length:
        # It fits where it was: pad to the sectors it already owns and leave the header
        # alone, so no other chunk moves.
        record += b"\x00" * (length * SECTOR - len(record))
        body = bytearray(raw[offset * SECTOR + length * SECTOR:])
        head = bytearray(raw[:8192])
        data = bytearray(raw[:offset * SECTOR]) + record + bytes(body)
        moved = "in place"
    else:
        # It grew. Append it at the end of the file and repoint this one slot; the sectors
        # it used to own become a hole, which the format allows (they are only reachable
        # through the header).
        head = bytearray(raw[:8192])
        words = (len(raw) + SECTOR - 1) // SECTOR
        if words < 2:
            words = 2
        data = bytearray(raw[:words * SECTOR])
        if len(data) < words * SECTOR:
            data += b"\x00" * (words * SECTOR - len(data))
        record += b"\x00" * (need * SECTOR - len(record))
        data += record
        head[slot * 4:slot * 4 + 4] = struct.pack(">I", (words << 8) | need)
        moved = f"moved to sector {words} ({length} sectors freed, {need} used)"

    data[0:8192] = head
    with open(path, "wb") as f:
        f.write(bytes(data))

    print(f"status: {path} chunk {coords[0]},{coords[1]} (slot {slot}): "
          f"{old.decode(errors='replace')} -> {status}, {moved}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
