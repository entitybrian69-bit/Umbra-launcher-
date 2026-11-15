#!/usr/bin/env python3
"""An independent Anvil region writer (the format minecraft.wiki documents)
used to build fixtures for the Goose reader: two chunks with paletted sections,
heightmaps and biomes, at the coordinates a 26.3 world uses."""
import json, os, struct, zlib

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "goose", "test", "fixtures", "region"))

def s(t):
    b = t.encode(); return struct.pack(">H", len(b)) + b
def tag(tid, name, payload): return bytes([tid]) + s(name) + payload
def byte(n, v): return tag(1, n, struct.pack(">b", v))
def int_(n, v): return tag(3, n, struct.pack(">i", v))
def long_(n, v): return tag(4, n, struct.pack(">q", v))
def string(n, v): return tag(8, n, s(v))
def list_(n, elem, items): return tag(9, n, bytes([elem]) + struct.pack(">i", len(items)) + b"".join(items))
def compound(n, children): return tag(10, n, b"".join(children) + b"\x00")
def payload_compound(children): return b"".join(children) + b"\x00"  # a list element: no name
def long_array(n, vals): return tag(12, n, struct.pack(">i", len(vals)) + b"".join(struct.pack(">q", (v & 0xFFFFFFFFFFFFFFFF) - (1 << 64) if v & 0x8000000000000000 else (v & 0xFFFFFFFFFFFFFFFF)) for v in vals))

STATES = [
    ("minecraft:air", {}),
    ("minecraft:stone", {}),
    ("minecraft:dirt", {}),
    ("minecraft:grass_block", {"snowy": "false"}),
    ("minecraft:oak_log", {"axis": "y"}),
    ("minecraft:oak_leaves", {"distance": "7", "persistent": "false", "waterlogged": "false"}),
    ("minecraft:water", {"level": "0"}),
    ("minecraft:sand", {}),
    ("minecraft:cobblestone", {}),
    ("minecraft:gravel", {}),
    ("minecraft:coal_ore", {}),
    ("minecraft:iron_ore", {}),
    ("minecraft:short_grass", {"half": "bottom"}),
]

def state_tag(name, props):
    kids = [string("Name", name)]
    if props:
        kids.append(compound("Properties", [string(k, v) for k, v in props.items()]))
    return payload_compound(kids)

def pack(indices, bits):
    words = [0] * ((4096 * bits + 63) // 64)
    for i, v in enumerate(indices):
        bit = i * bits
        li, shift = divmod(bit, 64)
        words[li] |= (v << shift) & 0xFFFFFFFFFFFFFFFF
        if shift + bits > 64:
            words[li + 1] |= v >> (64 - shift)
    return words

def section(y, ids_by_pos, palette_ids, blocks):
    """Build one section's NBT from a 16x16x16 array of palette indices."""
    used = sorted(set(ids_by_pos))
    bits = max(4, (len(used) - 1).bit_length())
    local = {gid: i for i, gid in enumerate(used)}
    indices = [local[g] for g in ids_by_pos]
    pal = [state_tag(*STATES[g]) for g in used]
    bs = compound("block_states", [
        list_("palette", 10, pal),
        long_array("data", pack(indices, bits)),
    ])
    biomes = compound("biomes", [
        list_("palette", 8, [s("minecraft:plains"), s("minecraft:forest")]),
        long_array("data", pack([(i % 2) for i in range(64)], 1)),
    ])
    return payload_compound([
        byte("Y", y), bs, biomes,
        byte("TisRO", 0), byte("TisLight", 0),
    ])

def heightmap(words):
    return long_array("MOTION_BLOCKING", words)

def chunk(cx, cz, seed):
    sections = []
    heights = [96] * 256
    # y=-4..19 is the 26.3 range; fill -4..2 with stone/dirt/grass, and put
    # a small structure and water into the surface section.
    for sy in range(-4, 8):
        ids = []
        for i in range(4096):
            yy = i // 256
            zz = (i // 16) % 16
            xx = i % 16
            world_y = sy * 16 + yy
            gx, gz = cx * 16 + xx, cz * 16 + zz
            if world_y < 60:
                gid = 1  # stone
                if (gx * 7 + gz * 13 + world_y) % 97 == 0:
                    gid = 10  # coal ore
            elif world_y < 63:
                gid = 2  # dirt
            elif world_y == 63:
                gid = 3  # grass
                if gx % 11 == 0 and gz % 7 == 0:
                    gid = 12  # short grass
            elif world_y == 64 and 4 <= xx <= 7 and 4 <= zz <= 7:
                gid = 6    # water pond
            elif 64 <= world_y <= 68 and abs(xx - 8) <= 1 and abs(zz - 8) <= 1:
                gid = 4    # oak log trunk
            elif 69 <= world_y <= 71 and abs(xx - 8) <= 2 and abs(zz - 8) <= 2:
                gid = 5    # leaves
            else:
                gid = 0
            ids.append(gid)
        sections.append(section(sy, ids, None, None))
    root = b"\x0a" + s("")
    kids = [
        int_("DataVersion", 3955),
        int_("xPos", cx),
        int_("zPos", cz),
        int_("yPos", -4),
        string("Status", "minecraft:full"),
        long_("LastUpdate", 1763200000 + seed),
        long_("InhabitedTime", 1234),
        list_("sections", 10, sections),
        compound("Heightmaps", [heightmap(pack(heights, 9))]),
        compound("block_entities", []),
        compound("structures", [compound("starts", []), compound("References", [])]),
        byte("isLightOn", 1),
    ]
    return root + b"".join(kids) + b"\x00"

def region(chunks):
    """chunks: dict {(cx,cz): nbt_bytes}"""
    locations = [(0, 0)] * 1024
    bodies = []
    sector = 2
    order = list(chunks.items())
    for (cx, cz), data in order:
        z = zlib.compress(data, 6)
        rec = struct.pack(">I", len(z) + 1) + b"\x02" + z
        n = (len(rec) + 4095) // 4096
        idx = (cx & 31) + (cz & 31) * 32
        locations[idx] = (sector, n)
        bodies.append(rec + b"\x00" * (n * 4096 - len(rec)))
        sector += n
    head = b"".join(struct.pack(">I", (o << 8) | c if o else 0) for o, c in locations)
    stamps = b"".join(struct.pack(">I", 1763200000 if locations[i][0] else 0) for i in range(1024))
    return head + stamps + b"".join(bodies), [(cx, cz) for (cx, cz) in chunks]

def main():
    os.makedirs(BASE, exist_ok=True)
    chunks = {(0, 0): chunk(0, 0, 1), (1, 0): chunk(1, 0, 2), (0, 1): chunk(0, 1, 3)}
    data, order = region(chunks)
    with open(os.path.join(BASE, "r.0.0.mca"), "wb") as f:
        f.write(data)
    meta = {"regions": [{"file": "r.0.0.mca", "chunks": [{"x": x, "z": z} for x, z in order]}],
            "states": [{"name": n, "props": p} for n, p in STATES]}
    with open(os.path.join(BASE, "manifest.json"), "w") as f:
        json.dump(meta, f, indent=1)
    # Broken regions the reader must refuse.
    broken = {
        "bad_offset": bytes([0, 0, 0xFF, 0x02]) + data[4:],
        "empty": b"",
        "header_only": data[:4096],
    }
    for n, d in broken.items():
        with open(os.path.join(BASE, f"bad_{n}.mca"), "wb") as f:
            f.write(d)
    print(f"region: r.0.0.mca {len(data)} bytes, {len(chunks)} chunks, {len(STATES)} states, {len(broken)} broken")

if __name__ == "__main__":
    main()
