#!/usr/bin/env python3
"""Write a small Anvil save with blocks at known positions, then check the reader.

usage: tools/make_test_save.py <world dir>

This is the fixture the real-world comparison cannot be: a chunk whose every block is
known, including the parts the synthetic world did not cover before -- sections below
y 0 (a section `Y` of -4 is y -64), a section whose palette needs five bits (the packing
changes above four entries), and a chunk far from the origin, so a reader that puts a
chunk at the wrong place cannot hide.

It writes `<world dir>/dimensions/minecraft/overworld/region/r.<x>.<z>.mca`, the 26.3
layout, and prints one `expect <x> <y> <z> <name>` line per block it placed, for the check
that follows.
"""
import os
import struct
import sys
import zlib

# --- NBT writing ---------------------------------------------------------

TAG_END, TAG_BYTE, TAG_INT, TAG_LONG, TAG_STRING, TAG_LIST, TAG_COMPOUND = 0, 1, 3, 4, 8, 9, 10


def _name(s):
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def tag(tid, name, payload):
    return bytes([tid]) + (b"" if tid == TAG_END else _name(name)) + payload


def compound(name, children):
    return tag(TAG_COMPOUND, name, b"".join(children)) + b"\x00"


def string(name, value):
    b = value.encode()
    return tag(TAG_STRING, name, struct.pack(">H", len(b)) + b)


def int_tag(name, value):
    return tag(TAG_INT, name, struct.pack(">i", value))


def long_tag(name, value):
    return tag(TAG_LONG, name, struct.pack(">q", value))


def list_of_compound(name, items):
    body = b"".join(b"".join(i) if isinstance(i, list) else i for i in items)
    return tag(TAG_LIST, name, bytes([TAG_COMPOUND]) + struct.pack(">i", len(items))) + body


def root_nbt(payload):
    return bytes([TAG_COMPOUND]) + _name("") + payload + b"\x00"


# --- a chunk with known blocks -------------------------------------------

# Palette with five entries: five bits per index, which is the packing the reader has to
# get right (four bits is the width the two packings agree on).
PALETTE_5 = ["minecraft:air", "minecraft:stone", "minecraft:deepslate",
             "minecraft:andesite", "minecraft:dirt"]


def packed_data(indices, bits):
    """4096 indices, packed so a value may run on across a word boundary (1.16+)."""
    words = [0] * ((4096 * bits + 63) // 64)
    for i, v in enumerate(indices):
        bit = i * bits
        li, shift = bit // 64, bit % 64
        words[li] |= (v & ((1 << bits) - 1)) << shift
        if shift + bits > 64:
            words[li + 1] |= (v & ((1 << bits) - 1)) >> (64 - shift)
    out = b"".join(struct.pack(">q", w if w < (1 << 63) else w - (1 << 64)) for w in words)
    return out


def block_states(palette, indices):
    """A `block_states` compound. One entry and no data covers a solid section."""
    entries = [compound("", [string("Name", p)]) for p in palette]
    kids = [list_of_compound("palette", entries)]
    if len(palette) > 1:
        bits = max(4, (len(palette) - 1).bit_length())
        kids.append(tag(TAG_LONG, "data", b"") if False else long_array("data", packed_data(indices, bits), (4096 * bits + 63) // 64))
    return compound("block_states", kids)


def long_array(name, raw, count):
    return tag(12, name, struct.pack(">i", count) + raw)   # TAG_LONG_ARRAY


def section(y, palette, indices):
    return [tag(TAG_BYTE, "Y", struct.pack(">b", y)), block_states(palette, indices)]


def build_expect():
    """The blocks this save holds, as (x, y, z, name)."""
    expect = []
    # Bottom section of chunk (0, 0): solid bedrock, a one-entry palette with no data.
    for x in range(16):
        for z in range(16):
            expect.append((x, -64, z, "minecraft:bedrock"))
    # A mixed section at y 48..63 with five palette entries.
    for x in range(16):
        for z in range(16):
            for y in range(48, 64):
                name = PALETTE_5[((x * 3 + z * 5 + y) % 4) + 1]
                expect.append((x, y, z, name))
    return expect


def chunk_nbt(cx, cz, sections, expect_shift):
    kids = [int_tag("DataVersion", 3955), int_tag("xPos", cx), int_tag("zPos", cz),
            string("Status", "minecraft:full"), list_of_compound("sections", sections)]
    return root_nbt(b"".join(kids))


def indices_for(palette, pick):
    return [pack_for(palette, pick(x, y, z)) for y in range(16) for z in range(16) for x in range(16)]


def pack_for(palette, name):
    return palette.index(name)


def region_file(chunks):
    """chunks: {(cx, cz): nbt bytes} -> a region file holding them."""
    header = bytearray(8192)
    body = bytearray()
    sector = 2
    for (cx, cz), nbt in sorted(chunks.items()):
        data = zlib.compress(nbt)
        record = struct.pack(">I", len(data) + 1) + b"\x02" + data
        pad = (-len(record)) % 4096
        record += b"\x00" * pad
        sectors = len(record) // 4096
        if sectors > 255:
            raise SystemExit("chunk too big for one record")
        idx = ((cx & 31) + (cz & 31) * 32) * 4
        header[idx:idx + 4] = struct.pack(">I", (sector << 8) | sectors)
        body += record
        sector += sectors
    return bytes(header) + bytes(body)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    world = sys.argv[1]
    region_dir = os.path.join(world, "dimensions", "minecraft", "overworld", "region")
    os.makedirs(region_dir, exist_ok=True)
    os.makedirs(os.path.join(world, "level.dat.d"), exist_ok=True)

    expect = build_expect()
    by_chunk = {}
    for (x, y, z, name) in expect:
        by_chunk.setdefault((0, 0), []).append((x, y, z, name))

    # Solid bottom section: one palette entry, no data.
    bottom = [section(-4, ["minecraft:bedrock"], None)]
    # The mixed section: five entries, five bits.
    mixed = [section(3, PALETTE_5,
                     indices_for(PALETTE_5, lambda x, y, z: PALETTE_5[((x * 3 + z * 5 + (y + 48)) % 4) + 1]))]

    chunks = {(0, 0): chunk_nbt(0, 0, bottom + mixed, 0)}
    # A second chunk, four chunks away, so a reader that ignores xPos/zPos puts its
    # blocks in the wrong place.
    far = [section(-4, ["minecraft:bedrock"], None),
           section(3, ["minecraft:stone"], None)]
    chunks[(4, -4)] = chunk_nbt(4, -4, far, 0)

    # One region file per 32x32 square; both chunks are inside r.0.-1? Chunk (4,-4) is in
    # r.0.-1, chunk (0,0) in r.0.0, so two files.
    groups = {}
    for (cx, cz), nbt in chunks.items():
        groups.setdefault((cx // 32, cz // 32), {})[(cx, cz)] = nbt
    for (rx, rz), members in groups.items():
        path = os.path.join(region_dir, f"r.{rx}.{rz}.mca")
        with open(path, "wb") as f:
            f.write(region_file(members))
        print(f"wrote {path}: {len(members)} chunk(s)")

    with open(os.path.join(world, "expect.txt"), "w") as f:
        for (x, y, z, name) in expect:
            f.write(f"{x} {y} {z} {name}\n")
        for x in range(4 * 16, 4 * 16 + 16):
            for z in range(-4 * 16, -4 * 16 + 16):
                f.write(f"{x} -64 {z} minecraft:bedrock\n")
                f.write(f"{x} 48 {z} minecraft:stone\n")
    print(f"expected blocks written to {os.path.join(world, 'expect.txt')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
