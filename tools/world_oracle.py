#!/usr/bin/env python3
"""An independent reader for the same Anvil world, written a second time.

The Goose reader (`goose/worldload.goose`) is what the renderer uses. This is a second
implementation of the same format, so "the world loaded" is two readers agreeing over a
file rather than one reader agreeing with itself. It prints the same records in the
same order:

    chunk <cx> <cz> blocks <n> hash <h>
    block <name> <count>
    total <chunks> <blocks> <states>
    detail <x> <y> <z> <name>[<props>]

usage: tools/world_oracle.py <world dir> <out.txt> [detail radius]
"""
import os
import struct
import sys
import zlib

AIR = {"minecraft:air", "minecraft:cave_air", "minecraft:void_air"}
FNV_OFFSET = 14695981039346656037
FNV_PRIME = 1099511628211


# --- NBT -----------------------------------------------------------------

class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def take(self, n):
        v = self.d[self.p:self.p + n]
        self.p += n
        return v

    def num(self, fmt, n):
        return struct.unpack(">" + fmt, self.take(n))[0]

    def string(self):
        n = self.num("H", 2)
        return self.take(n).decode("utf-8", "replace")


def payload(r, tid):
    if tid == 1:
        return r.num("b", 1)
    if tid == 2:
        return r.num("h", 2)
    if tid == 3:
        return r.num("i", 4)
    if tid == 4:
        return r.num("q", 8)
    if tid == 5:
        return r.num("f", 4)
    if tid == 6:
        return r.num("d", 8)
    if tid == 7:
        return r.take(r.num("i", 4))
    if tid == 8:
        return r.string()
    if tid == 9:
        sub = r.num("B", 1)
        n = r.num("i", 4)
        return [payload(r, sub) for _ in range(n)]
    if tid == 10:
        out = []
        while True:
            t = r.num("B", 1)
            if t == 0:
                return out
            out.append((r.string(), payload(r, t)))
    if tid == 11:
        n = r.num("i", 4)
        return list(struct.unpack(">%di" % n, r.take(4 * n)))
    if tid == 12:
        n = r.num("i", 4)
        return list(struct.unpack(">%dq" % n, r.take(8 * n)))
    raise ValueError(f"nbt: unknown tag {tid} at {r.p}")


def parse(data):
    r = Reader(data)
    if r.num("B", 1) != 10:
        raise ValueError("nbt: root is not a compound")
    r.string()
    return payload(r, 10)


def get(node, name, default=None):
    for k, v in node:
        if k == name:
            return v
    return default


# --- sections ------------------------------------------------------------

def section_states(sec):
    """(palette, indices) where palette is [(name, props_text)], or (None, None)."""
    bs = get(sec, "block_states")
    if bs is None:
        return None, None
    palette = []
    for entry in get(bs, "palette", []) or []:
        # A palette entry is either a compound {Name, Properties} or, for a state with no
        # properties, the bare name - which is what 26.3 writes, and what made this reader
        # raise instead of reading the save.
        if isinstance(entry, str):
            palette.append((entry, ""))
            continue
        name = get(entry, "Name", "minecraft:air")
        props = ",".join(f"{k}={v}" for k, v in (get(entry, "Properties", []) or []))
        palette.append((name, props))
    if not palette:
        return None, None
    data = get(bs, "data")
    if data is None:
        return palette, [0] * 4096
    bits = max(4, (len(palette) - 1).bit_length())
    per = 64 // bits
    mask = (1 << bits) - 1
    out = []
    for word in data:
        w = word & 0xFFFFFFFFFFFFFFFF
        for k in range(per):
            out.append((w >> (k * bits)) & mask)
        if len(out) >= 4096:
            break
    return palette, out[:4096]


def chunk_records(nbt, radius):
    root = parse(nbt)
    body = get(root, "Level") or root
    cx = get(body, "xPos", 0)
    cz = get(body, "zPos", 0)

    sections = {}
    for sec in get(body, "sections", []) or []:
        palette, indices = section_states(sec)
        if palette is None:
            continue
        sections[get(sec, "Y", 0)] = (palette, indices)

    state_counts = {}
    detail = []
    h = FNV_OFFSET
    blocks = 0

    def hbyte(b):
        nonlocal h
        h = ((h ^ b) * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF

    def hstr(s):
        for b in s.encode():
            hbyte(b)
        hbyte(0)

    def hi32(v):
        for k in range(4):
            hbyte((v >> (k * 8)) & 0xFF)

    detailed = -radius <= cx <= radius and -radius <= cz <= radius
    # World y ascending, then z, then x: the order the Goose reader walks a column in,
    # which is also the order the game packs a section (x fastest, then z, then y).
    if sections:
        lo = min(sections) * 16
        hi = max(sections) * 16 + 16
        for wy in range(lo, hi):
            sy, ly = wy // 16, wy % 16
            if sy not in sections:
                continue
            palette, indices = sections[sy]
            for z in range(16):
                for x in range(16):
                    index = ((ly * 16) + z) * 16 + x
                    name, props = palette[indices[index]]
                    if name in AIR:
                        continue
                    gx = cx * 16 + x
                    gz = cz * 16 + z
                    hi32(gx)
                    hi32(wy)
                    hi32(gz)
                    hstr(name)
                    hstr(props)
                    blocks += 1
                    state_counts[name] = state_counts.get(name, 0) + 1
                    if detailed:
                        doc = f"{gx} {wy} {gz} {name}"
                        if props:
                            doc += f"[{props}]"
                        detail.append("detail " + doc)
    return cx, cz, blocks, h, state_counts, detail


def file_chunks(path):
    """Every chunk in one .mca: the header holds where each 32x32 slot lives."""
    data = open(path, "rb").read()
    out = []
    for cz in range(32):
        for cx in range(32):
            i = (cx + cz * 32) * 4
            v = struct.unpack(">I", data[i:i + 4])[0]
            offset, sectors = v >> 8, v & 0xFF
            if offset == 0 or sectors == 0:
                continue
            start = offset * 4096
            length = struct.unpack(">I", data[start:start + 4])[0]
            kind = data[start + 4]
            payload_bytes = data[start + 5:start + 4 + length]
            if kind == 1:
                nbt = zlib.decompress(payload_bytes, -15)
            elif kind == 2:
                nbt = zlib.decompress(payload_bytes)
            elif kind == 3:
                nbt = payload_bytes
            else:
                raise ValueError(f"{path}: chunk {cx},{cz} compression {kind}")
            out.append(nbt)
    return out


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    world = sys.argv[1]
    out_path = sys.argv[2]
    radius = int(sys.argv[3]) if len(sys.argv) > 3 else 1

    # The classic layout keeps the overworld in <world>/region; 26.3 keeps it in
    # <world>/dimensions/minecraft/overworld/region. Both are asked, in that order, and the
    # answer is printed so the two readers' logs name the same directory.
    region_dir = os.path.join(world, "region")
    if not os.path.isdir(region_dir):
        alt = os.path.join(world, "dimensions", "minecraft", "overworld", "region")
        if os.path.isdir(alt):
            region_dir = alt
    print(f"oracle: region dir {region_dir}")
    files = sorted(f for f in os.listdir(region_dir) if f.endswith(".mca"))
    if not files:
        print(f"oracle: FAIL no region files in {region_dir}", file=sys.stderr)
        return 1

    lines = []
    detail = []
    chunks = 0
    blocks = 0
    states = {}
    for name in files:
        for nbt in file_chunks(os.path.join(region_dir, name)):
            try:
                cx, cz, n, h, counts, det = chunk_records(nbt, radius)
            except (ValueError, struct.error) as exc:
                print(f"oracle: FAIL {name}: the chunk is not the shape this reader expects: {exc}",
                      file=sys.stderr)
                return 1
            lines.append(f"chunk {cx} {cz} blocks {n} hash {h}")
            chunks += 1
            blocks += n
            for k, v in counts.items():
                states[k] = states.get(k, 0) + v
            detail.extend(det)

    block_lines = [f"block {k} {states[k]}" for k in sorted(states) if states[k]]
    total = f"total {chunks} {blocks} {len(block_lines)}"
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
        f.write("\n".join(block_lines) + "\n")
        f.write(total + "\n")
        f.write("\n".join(detail))
        if detail:
            f.write("\n")
    print(f"oracle: chunks {chunks}, non-air blocks {blocks}, states {len(block_lines)}, "
          f"region files {len(files)}")
    print(f"oracle: wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
