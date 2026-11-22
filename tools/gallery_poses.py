#!/usr/bin/env python3
"""Six fixed poses in the save, chosen from the save's own terrain.

Why poses come from a tool and not from a list of coordinates: the world the phone opens is
one the game generated, and its hills, forests and shores are wherever they are. Hard-coded
numbers would put the camera inside a hill the first time the world changed, and the gallery
would show the inside of a block -- which looks like a renderer bug and is not one.

So this reads the save's region files *as a column of blocks* and picks, for each picture, a
place that has the thing the picture is supposed to show:

  hills    the highest ground in the save, looking down at the slope
  forest   a column whose sections name logs, at eye height
  shore    a column that names water, looking along the waterline
  cave     under the terrain, looking up at the roof
  sky      above the highest ground, looking at the horizon
  edge     the easternmost column, looking out along the edge of the window

It writes one line per pose in the form `pose.txt` reads: `x y z yaw pitch`, y being the
body's feet, yaw and pitch in radians.

WHY IT DECODES BLOCKS AND NOT TEXT. It used to hunt for byte strings in the chunk's NBT: find
every `Y` byte tag, look 8000 bytes past it for `minecraft:stone`, and take that section's own
`sy * 16 + 15` as ground height. Two things were wrong with that, and both were silent:

  * a section index is a *window*, not a height -- section 19 says "somewhere in y 304..319",
    and every one of the sixteen y values in it is air. Section 19 is exactly what 26.3 writes
    above a y-91 hilltop, and run 44938399066 put the gallery camera at y 320.01 on the
    strength of it. The screenshot that came back was pure sky with the nav bar in it -- a
    true picture of nothing, 14 581 bytes, which the byte-count gate then called "not a
    picture" for the wrong reason;
  * the 8000-byte window ran past the end of its own section into the next one, so the air
    section above the last stone borrowed its neighbour's palette and was called ground.

Picking a pose from a number that is not where the ground is cannot be fixed by posing
harder, so this reads the palette and the packed indices the way `tools/world_oracle.py`
does -- a second reader of the same format -- and counts blocks per y. Air is air.

The argument is either a save directory or the world.zip the phone was given. The archive is
the better one: the phone opens the archive, so reading the same bytes is the only way this
tool and the renderer can be talking about one world. Run 44951752864 is what the difference
looks like -- the tool read `world/region` (stale spawn-preparation terrain) while the phone
was given `world/dimensions/minecraft/overworld/region`, and the two disagreed about the same
column by 33 blocks: the tool said the ground was at y 107, the renderer said y 73.

usage: tools/gallery_poses.py <save dir | world.zip> [--out FILE] [--explain]
"""
import os
import struct
import sys
import zlib

AIR = {"minecraft:air", "minecraft:cave_air", "minecraft:void_air"}

# A block that is ground to stand on, as opposed to a thing that grows or falls.
GROUND = ("stone", "dirt", "grass_block", "sand", "gravel", "deepslate", "tuff",
          "andesite", "diorite", "granite", "podzol", "mycelium", "snow_block",
          "sandstone", "terracotta", "clay", "coal_ore", "iron_ore", "copper_ore")


# --- NBT ------------------------------------------------------------------
#
# A minimal tag walker, the same shape as the one in `tools/world_oracle.py`: this reads a
# chunk's `sections` list and nothing else, and it has to cope with both paletted-container
# forms (the 26.3 `{id, properties}` entries and the older `{Name, Properties}` ones).

class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def take(self, n):
        v = self.d[self.p:self.p + n]
        if len(v) != n:
            raise ValueError("nbt: ran off the end")
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
        n = r.num("i", 4)
        return r.take(n)
    if tid == 8:
        return r.string()
    if tid == 9:
        et = r.num("b", 1)
        n = r.num("i", 4)
        return [payload(r, et) for _ in range(max(0, n))]
    if tid == 10:
        out = []
        while True:
            t = r.num("b", 1)
            if t == 0:
                return out
            name = r.string()
            out.append((name, payload(r, t)))
    if tid == 11:
        n = r.num("i", 4)
        return [r.num("i", 4) for _ in range(n)]
    if tid == 12:
        n = r.num("i", 4)
        return [r.num("q", 8) for _ in range(n)]
    raise ValueError(f"nbt: tag type {tid}")


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


# --- sections -------------------------------------------------------------

def section_palette(sec):
    """(palette names, indices) for one section, or (None, None) if it holds no states."""
    bs = get(sec, "block_states")
    if bs is None:
        return None, None
    palette = []
    for entry in get(bs, "palette", []) or []:
        name = None
        if isinstance(entry, str):
            name = entry
        else:
            name = get(entry, "Name")
            if name is None:
                name = get(entry, "id")
            if name is None and len(entry) == 1 and isinstance(entry[0][1], str):
                name = entry[0][1]
        palette.append(name or "minecraft:air")
    if not palette:
        return None, None
    data = get(bs, "data")
    if data is None:
        # A single-state section: the game writes the palette and no data at all.
        return palette, [0] * 4096
    bits = max(4, (len(palette) - 1).bit_length())
    mask = (1 << bits) - 1
    # Two packings exist and the length says which: since 1.16 a value runs on across a
    # word boundary, so there are ceil(4096 * bits / 64) longs; before that each word
    # started a new value, so there are ceil(4096 / (64 // bits)). They differ at 5, 6 and
    # 7 bits, and reading one as the other turns a real save into a different world
    # (958903 blocks one way, 732557 the other, on the same file). This is the same
    # arithmetic `tools/world_oracle.py` uses, and the two are checked against one file.
    per = 64 // bits
    padded_longs = (4096 + per - 1) // per
    contiguous = len(data) != padded_longs or bits == 4
    out = [0] * 4096
    words = [w & 0xFFFFFFFFFFFFFFFF for w in data]
    for i in range(4096):
        if contiguous:
            bit = i * bits
            li = bit // 64
            shift = bit % 64
            if li >= len(words):
                break
            v = words[li] >> shift
            if shift + bits > 64 and li + 1 < len(words):
                v |= words[li + 1] << (64 - shift)
            out[i] = v & mask
        else:
            li = i // per
            if li >= len(words):
                break
            out[i] = (words[li] >> ((i % per) * bits)) & mask
    return palette, out


def read_column(nbt):
    """What one chunk says about its own terrain, as blocks rather than as bytes.

    Returns (counts, top, water, log): `counts[y]` is how many non-air blocks sit at that
    world y in this chunk, `top` the highest ground block, and the two flags whether the
    chunk names water (at or below the surface) or a log.
    """
    root = parse(nbt)
    body = get(root, "Level") or root
    counts = {}
    top = -999
    water = False
    log = False
    for sec in get(body, "sections", []) or []:
        palette, indices = section_palette(sec)
        if palette is None:
            continue
        sy = get(sec, "Y", 0)
        base = sy * 16
        for i, idx in enumerate(indices):
            name = palette[idx] if idx < len(palette) else "minecraft:air"
            if name in AIR:
                continue
            # y is the slowest axis: (y * 16 + z) * 16 + x, x fastest.
            wy = base + (i // 256)
            counts[wy] = counts.get(wy, 0) + 1
            bare = name.split(":", 1)[-1]
            if bare == "water":
                water = True
            elif bare.endswith("_log") or bare == "log":
                log = True
            elif any(bare.endswith(g) for g in GROUND):
                if wy > top:
                    top = wy
    return counts, top, water, log


def find_region_dir(save_dir):
    """Where the terrain regions are, wherever this version of the game puts them.

    A 26.3 save keeps the overworld's regions under a dimension path, not directly in
    `region/`, and the workflow already prefers that layout for the archive it hands the
    phone (`dimensions/minecraft/overworld/region`). This function has to make the same
    choice, for the same reason `tools/zip_world.py` refuses two layouts with the same file
    names: a 26.3 server leaves `world/region/r.0.0.mca` behind from spawn preparation
    beside the real terrain, and they are *different worlds* with the same names.

    So: the dimensions layout first, then the top-level `region/`, then the shallowest
    match. "Shallowest" alone was wrong in run 44951752864 -- it picked the stale one -- and
    the symptom was a camera 33 blocks above the ground the renderer drew.

    `entities/r.x.z.mca` files are deliberately not candidates: the same names hold NBT
    that is not a chunk, which is the bug that made a phone open a world of 0 blocks once.
    """
    direct = os.path.join(save_dir, "region")
    candidates = []
    for root, dirs, files in os.walk(save_dir):
        if os.path.basename(root) != "region":
            continue
        if os.path.basename(os.path.dirname(root)) == "entities":
            continue
        if any(n.endswith(".mca") for n in files):
            candidates.append(root)
    if not candidates:
        return None
    # Rank: a dimensions path wins whatever its depth; then the top-level `region/`; then
    # the shallowest, which is the nearest to the save's root.
    def rank(path):
        p = path.replace(os.sep, "/")
        dims = "/dimensions/" in p
        return (0 if dims else (1 if path == direct else 2), path.count(os.sep))
    return sorted(candidates, key=rank)[0]


def region_entries(source):
    """(name, bytes reader) for every region file in a save directory or a world archive.

    An archive is the better source: the phone is given the archive, so the bytes read here
    are the bytes it opens. The names inside are `region/r.x.z.mca` -- what
    `tools/zip_world.py` writes and what `core/worldload_in.goose` looks for.
    """
    if os.path.isfile(source) and source.endswith(".zip"):
        import zipfile
        zf = zipfile.ZipFile(source)
        out = []
        for info in zf.infolist():
            if info.is_dir():
                continue
            p = info.filename.replace("\\", "/")
            if not p.endswith(".mca"):
                continue
            if p.split("/")[-2:-1] != ["region"]:
                continue  # entities/, or something else with a region file's name
            out.append((os.path.basename(p), lambda i=info: zf.read(i)))
        return out
    region_dir = find_region_dir(source)
    if region_dir is None:
        return []
    return [(n, (lambda d=region_dir, n=n: open(os.path.join(d, n), "rb").read()))
            for n in sorted(os.listdir(region_dir)) if n.endswith(".mca")]


def load_columns(save_dir):
    cols = {}
    for name, read in region_entries(save_dir):
        try:
            parts = name.split(".")
            rx, rz = int(parts[1]), int(parts[2])
            data = read()
        except (ValueError, IndexError, OSError):
            continue
        for slot in range(1024):
            if slot * 4 + 4 > len(data):
                break
            entry = struct.unpack(">I", data[slot * 4:slot * 4 + 4])[0]
            if entry == 0:
                continue
            off, count = entry >> 8, entry & 0xFF
            rec = data[off * 4096:off * 4096 + count * 4096]
            if len(rec) < 5:
                continue
            ln = struct.unpack(">I", rec[:4])[0]
            try:
                comp = rec[4]
                if comp not in (1, 2):
                    continue
                raw = rec[5:4 + ln]
                nbt = zlib.decompress(raw) if comp == 2 else raw
                got = read_column(nbt)
            except (zlib.error, ValueError, struct.error, IndexError):
                # A chunk this tool cannot read is one this tool must not guess at: the
                # pose it would pick is the wrong picture, silently.
                continue
            cx = rx * 32 + (slot % 32)
            cz = rz * 32 + (slot // 32)
            cols[(cx, cz)] = got
    return cols


def eye(counts, clearance=2):
    """A y where the camera is in air, standing just above the highest block.

    The one thing that must be true of a pose is that the camera is not *inside* a block:
    that picture looks like a renderer drawing solid black and is not one. `counts` is the
    number of non-air blocks at each world y over the whole 16x16 column, so "the two rows
    above this y hold no blocks at all" is a proof about every cell in the column, not a
    guess about the one the camera is in.

    Walking down from the top matters: the highest block in a forest column is a leaf, and
    a camera at leaf height + 1 with the canopy two rows above it is still in the open.
    """
    for y in sorted(counts, reverse=True):
        if all(counts.get(y + k, 0) == 0 for k in range(1, clearance + 1)):
            return y + 1.01
    top = max(counts) if counts else -999
    return top + 1.01


def pick(name, cols, centre):
    cx, cz = centre
    land = [(k, v) for k, v in cols.items() if v[1] > -999]
    if not land:
        return None
    by_near = sorted(land, key=lambda kv: (kv[0][0] - cx) ** 2 + (kv[0][1] - cz) ** 2)

    if name == "hills":
        (px, pz), (counts, top, _w, _l) = max(land, key=lambda kv: kv[1][1])
        y = eye(counts)
        return (px + 0.5, y, pz + 0.5, 0.7, -0.45, f"the highest ground in the save, {top}")
    if name == "forest":
        for (px, pz), (_c, top, _w, log) in by_near:
            if log:
                y = eye(cols[(px, pz)][0])
                return (px + 0.5, y, pz + 0.5, 0.9, -0.05, "a column with logs")
        return None
    if name == "shore":
        for (px, pz), (_c, top, water, _l) in by_near:
            if water:
                y = eye(cols[(px, pz)][0])
                return (px + 0.5, y, pz + 0.5, 1.6, -0.12, "a column with water")
        return None
    if name == "cave":
        # y 12 is under the terrain, so the shot has to look *down* at the stone and up at
        # the roof, not at the sky: a positive pitch from inside the ground is a picture of
        # a hole with daylight in it. -0.05 is level, which at this depth is a wall of
        # stone and the shadow the brief's "cave/dark interior" asks for.
        for (px, pz), (_c, top, _w, _l) in by_near:
            if top > 20:
                return (px + 0.5, 12.01, pz + 0.5, 2.4, -0.05, "under the terrain")
        return None
    if name == "sky":
        (px, pz), (counts, top, _w, _l) = max(land, key=lambda kv: kv[1][1])
        return (px + 0.5, top + 12.01, pz + 0.5, -1.2, -0.02, f"above the ground ({top})")
    if name == "edge":
        (px, pz), (_c, top, _w, _l) = max(land, key=lambda kv: kv[0][0])
        y = eye(cols[(px, pz)][0])
        return (px + 0.5, y, pz + 0.5, -1.5708, -0.06, "the easternmost column")
    return None


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    save_dir = sys.argv[1]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    cols = load_columns(save_dir)
    if not cols:
        # Say which directories were looked in, so the next failure of this kind is a fact
        # rather than a guess.
        seen = []
        for root, dirs, files in os.walk(save_dir):
            if any(n.endswith(".mca") for n in files):
                seen.append(root)
            if len(seen) >= 4:
                break
        raise SystemExit(f"{save_dir}: no region files (region/ or any */region/ dir; "
                         f"directories holding .mca files: {seen or 'none'})")
    xs = [k[0] for k in cols]
    zs = [k[1] for k in cols]
    centre = ((min(xs) + max(xs)) // 2, (min(zs) + max(zs)) // 2)
    rows = []
    for name in ("hills", "forest", "shore", "cave", "sky", "edge"):
        got = pick(name, cols, centre)
        if got is None:
            print(f"pose {name}: the save has nothing for it", file=sys.stderr)
            continue
        x, y, z, yaw, pitch, why = got
        rows.append((name, x, y, z, yaw, pitch))
        print(f"pose {name}: {x:.2f} {y:.2f} {z:.2f} yaw {yaw:.3f} pitch {pitch:.3f} -- {why}")
        if "--explain" in sys.argv:
            counts, top, water, log = cols[(int(x - 0.5), int(z - 0.5))]
            print(f"  column {int(x - 0.5)},{int(z - 0.5)}: top ground {top}, eye {y:.2f}, "
                  f"water {water}, log {log}, blocks above {int(y)}: "
                  f"{sum(n for k, n in counts.items() if k > int(y))}")
    if not rows:
        raise SystemExit("no pose could be placed in this save")
    if out:
        with open(out, "w") as f:
            for name, x, y, z, yaw, pitch in rows:
                f.write(f"{name} {x:.2f} {y:.2f} {z:.2f} {yaw:.3f} {pitch:.3f}\n")
        print(f"wrote {out}: {len(rows)} pose(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
