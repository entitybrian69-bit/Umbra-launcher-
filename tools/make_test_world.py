#!/usr/bin/env python3
"""Write a small Anvil world, in the format the game writes, for testing the reader.

This is not a game save and contains no game data: it is generated here, in Python, so
that the Goose reader and the Python oracle are two implementations reading a file
neither of them wrote. The real thing (`tools/fetch_server.sh` + a real server run) is
what proves the reader against a world the game made; this proves the two readers
against each other on every push.

usage: tools/make_test_world.py <out dir> [chunks]
"""
import os
import struct
import sys
import zlib


# --- NBT writing ---------------------------------------------------------

def tag(tid: int, name: str, payload: bytes) -> bytes:
    n = name.encode()
    return bytes([tid]) + struct.pack(">H", len(n)) + n + payload


def t_byte(v: int) -> bytes:
    return struct.pack(">b", v)


def t_int(v: int) -> bytes:
    return struct.pack(">i", v)


def t_long(v: int) -> bytes:
    return struct.pack(">q", v)


def t_string(s: str) -> bytes:
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def t_compound(members: list) -> bytes:
    return b"".join(members) + b"\x00"


def t_list(tid: int, items: list) -> bytes:
    return bytes([tid]) + struct.pack(">i", len(items)) + b"".join(items)


def t_long_array(values: list) -> bytes:
    return struct.pack(">i", len(values)) + b"".join(struct.pack(">q", v) for v in values)


# --- a chunk -------------------------------------------------------------

def pack_indices(indices: list, bits: int) -> list:
    """Vanilla packing since 1.16: entries are contiguous, with no padding between
    them across a 64-bit word boundary."""
    out = []
    per = 64 // bits
    word = 0
    filled = 0
    for v in indices:
        word |= (v & ((1 << bits) - 1)) << (filled * bits)
        filled += 1
        if filled == per:
            out.append(word)
            word = 0
            filled = 0
    if filled:
        out.append(word)
    return out


def section(y: int, fill: str, extra: dict) -> bytes:
    """One 16^3 section: `fill` for everything, with `extra` overriding cells. The
    palette is written in the order the states are first seen, like the game does."""
    palette = []
    cells = [None] * 4096

    def intern(state: dict) -> int:
        for i, s in enumerate(palette):
            if s == state:
                return i
        palette.append(state)
        return len(palette) - 1

    base = intern({"Name": fill})
    for i in range(4096):
        cells[i] = base
    for (x, yy, z), state in extra.items():
        cells[(yy * 16 + z) * 16 + x] = intern(state)

    bits = max(4, (len(palette) - 1).bit_length()) if len(palette) > 1 else 0
    entry = [
        tag(1, "Y", t_byte(y)),
    ]
    if bits == 0:
        # A single-state section: the game writes the palette with no data at all.
        entry.append(tag(10, "block_states", t_compound([
            tag(9, "palette", t_list(10, [t_compound([tag(8, "Name", t_string(palette[0]["Name"]))])])),
        ])))
    else:
        words = pack_indices(cells, bits)
        entry.append(tag(10, "block_states", t_compound([
            tag(9, "palette", t_list(10, [
                t_compound([tag(8, "Name", t_string(s["Name"]))]
                           + ([tag(10, "Properties", t_compound([
                               tag(8, k, t_string(v)) for k, v in sorted(s["Properties"].items())
                           ]))] if s.get("Properties") else []))
                for s in palette
            ])),
            tag(12, "data", t_long_array(words)),
        ])))
    # A list element carries no tag id and no name: just the compound's payload.
    return t_compound(entry)


def chunk(cx: int, cz: int, data_version: int, sections: list) -> bytes:
    body = t_compound([
        tag(3, "DataVersion", t_int(data_version)),
        tag(3, "xPos", t_int(cx)),
        tag(3, "zPos", t_int(cz)),
        tag(3, "yPos", t_int(-4)),
        tag(8, "Status", t_string("minecraft:full")),
        tag(9, "sections", t_list(10, sections)),
    ])
    return b"\x0a" + struct.pack(">H", 0) + body


# --- a region ------------------------------------------------------------

def region(chunks: dict) -> bytes:
    """chunks: {(cx, cz): nbt bytes}, cx and cz within 0..31."""
    header = bytearray(8192)
    body = bytearray()
    sector = 2
    for (cx, cz), nbt in sorted(chunks.items()):
        payload = zlib.compress(nbt, 6)
        record = struct.pack(">I", len(payload) + 1) + b"\x02" + payload
        pad = (-len(record)) % 4096
        record += b"\x00" * pad
        sectors = len(record) // 4096
        i = (cx + cz * 32) * 4
        header[i:i + 4] = struct.pack(">I", (sector << 8) | sectors)
        body += record
        sector += sectors
    return bytes(header) + bytes(body)


def surface(x: int, z: int) -> int:
    """A small height map: a hill, a dip that becomes a pond, and flat ground."""
    h = 64 + ((x * 13 + z * 7) % 5) - 2
    if (x % 11) == 5 and (z % 13) == 4:
        h -= 8
    return h


def build(out_dir: str, count: int) -> None:
    os.makedirs(os.path.join(out_dir, "region"), exist_ok=True)
    chunks = {}
    for cz in range(count):
        for cx in range(count):
            cells = {}
            for x in range(16):
                for z in range(16):
                    gx, gz = cx * 16 + x, cz * 16 + z
                    h = surface(gx, gz)
                    for wy in range(40, h):
                        if wy < h - 4:
                            state = {"Name": "minecraft:stone"}
                        elif wy < h - 1:
                            state = {"Name": "minecraft:dirt"}
                        else:
                            state = {"Name": "minecraft:grass_block",
                                     "Properties": {"snowy": "false"}}
                        cells[(x, wy, z)] = state
                    # A pond where the ground dips: water up to y=62, above the ground.
                    if h < 62:
                        for wy in range(h, 62):
                            cells[(x, wy, z)] = {"Name": "minecraft:water",
                                                 "Properties": {"level": "0"}}
            # A tree: oak logs, leaves over them, and a slab on the ground beside it.
            tx, tz = 4, 6
            base_y = surface(cx * 16 + tx, cz * 16 + tz)
            for dy in range(4):
                cells[(tx, base_y + dy, tz)] = {"Name": "minecraft:oak_log",
                                                "Properties": {"axis": "y"}}
            for dz in range(-1, 2):
                for dx in range(-1, 2):
                    for dy in range(2, 5):
                        p = (tx + dx, base_y + dy, tz + dz)
                        if 0 <= p[0] < 16 and 0 <= p[2] < 16 and p not in cells:
                            cells[p] = {"Name": "minecraft:oak_leaves",
                                        "Properties": {"distance": "7", "persistent": "false",
                                                       "waterlogged": "false"}}
            cells[(8, surface(cx * 16 + 8, cz * 16 + 8), 8)] = {
                "Name": "minecraft:oak_slab",
                "Properties": {"type": "bottom", "waterlogged": "false"}}

            # Sections from -4 to 5, each written only if it holds something: a section
            # the save omits is air, and the reader has to agree about that.
            sections = []
            for y in range(-4, 6):
                extra = {}
                for (x, wy, z), state in cells.items():
                    if wy // 16 != y:
                        continue
                    extra[(x, wy - y * 16, z)] = state
                if not extra:
                    continue
                sections.append(section(y, "minecraft:air", extra))
            chunks[(cx, cz)] = chunk(cx, cz, 4189, sections)
    with open(os.path.join(out_dir, "region", "r.0.0.mca"), "wb") as f:
        f.write(region(chunks))
    with open(os.path.join(out_dir, "level.dat"), "wb") as f:
        f.write(b"\x0a" + struct.pack(">H", 0) + t_compound([
            tag(10, "Data", t_compound([tag(3, "version", t_int(19133))])),
        ]))
    print(f"wrote {out_dir}: {len(chunks)} chunks in r.0.0.mca")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    build(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 2)
