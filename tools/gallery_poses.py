#!/usr/bin/env python3
"""Six fixed poses in the save, chosen from the save's own terrain.

Why poses come from a tool and not from a list of coordinates: the world the phone opens is
one the game generated, and its hills, forests and shores are wherever they are. Hard-coded
numbers would put the camera inside a hill the first time the world changed, and the gallery
would show the inside of a block -- which looks like a renderer bug and is not one.

So this reads the save's region files and picks, for each picture, a place that has the thing
the picture is supposed to show:

  hills    the highest ground in the save, looking down at the slope
  forest   a column whose sections name logs, at eye height
  shore    a column that names water, looking along the waterline
  cave     under the terrain, looking up at the roof
  sky      above the highest ground, looking at the horizon
  edge     the easternmost column, looking out along the edge of the window

It writes one line per pose in the form `pose.txt` reads: `x y z yaw pitch`, y being the
body's feet, yaw and pitch in radians.

usage: tools/gallery_poses.py <save dir> [--out FILE]
"""
import os
import struct
import sys
import zlib


def parse_column(nbt):
    """(highest solid section top, has water, has logs) for one column's NBT.

    A full NBT walker is not the point: this needs to know where the ground is and whether
    the column names water or a log. It reads the section compounds' own `Y` bytes and the
    palette strings after each one.
    """
    top = -999
    water = False
    log = False
    i = 0
    while True:
        i = nbt.find(b"\x01\x00\x01Y", i)
        if i < 0 or i + 5 > len(nbt):
            break
        sy = nbt[i + 4]
        if sy > 127:
            sy -= 256
        window = nbt[i:i + 8000]
        if b"minecraft:water" in window:
            water = True
        if b"_log" in window:
            log = True
        if (b"minecraft:stone" in window or b"minecraft:dirt" in window or
                b"minecraft:grass_block" in window or b"minecraft:sand" in window):
            top = max(top, sy * 16 + 15)
        i += 5
    return (top, water, log)


def find_region_dir(save_dir):
    """Where the terrain regions are, wherever this version of the game puts them.

    A 26.3 save keeps the overworld's regions under a dimension path, not directly in
    `region/`, and the workflow's own step already searches (`find ... -path
    '*/region/*.mca'`) for exactly that reason. This function only ever looked one level
    down, so on a save with the newer layout it found nothing and the gallery failed with
    "no region files" -- which reads like a broken save rather than a broken lookup.

    `entities/r.x.z.mca` files are deliberately not candidates: the same names hold NBT
    that is not a chunk, which is the bug that made a phone open a world of 0 blocks once.
    """
    direct = os.path.join(save_dir, "region")
    if os.path.isdir(direct) and any(n.endswith(".mca") for n in os.listdir(direct)):
        return direct
    best = None
    for root, dirs, files in os.walk(save_dir):
        if os.path.basename(root) != "region" or os.path.basename(os.path.dirname(root)) == "entities":
            continue
        if any(n.endswith(".mca") for n in files):
            # Prefer the shallowest match: a save can hold several dimensions, and the
            # overworld is the one nearest the top.
            depth = root.count(os.sep)
            if best is None or depth < best[0]:
                best = (depth, root)
    return best[1] if best else None


def load_columns(save_dir):
    region_dir = find_region_dir(save_dir)
    cols = {}
    if region_dir is None:
        return cols
    for name in sorted(os.listdir(region_dir)):
        if not name.endswith(".mca"):
            continue
        parts = name.split(".")
        rx, rz = int(parts[1]), int(parts[2])
        data = open(os.path.join(region_dir, name), "rb").read()
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
                nbt = zlib.decompress(rec[5:4 + ln])
            except zlib.error:
                continue
            cx = rx * 32 + (slot % 32)
            cz = rz * 32 + (slot // 32)
            cols[(cx, cz)] = parse_column(nbt)
    return cols


def pick(name, cols, centre):
    cx, cz = centre
    land = [(k, v[0]) for k, v in cols.items() if v[0] > -999]
    if not land:
        return None
    by_near = sorted(land, key=lambda kv: (kv[0][0] - cx) ** 2 + (kv[0][1] - cz) ** 2)

    if name == "hills":
        (px, pz), top = max(land, key=lambda kv: kv[1])
        return (px + 0.5, top + 1.01, pz + 0.5, 0.7, -0.45, f"highest ground, {top}")
    if name == "forest":
        for (px, pz), v in by_near:
            if cols[(px, pz)][2]:
                return (px + 0.5, v + 1.01, pz + 0.5, 0.9, -0.05, "a column with logs")
        return None
    if name == "shore":
        for (px, pz), v in by_near:
            if cols[(px, pz)][1]:
                return (px + 0.5, v + 1.01, pz + 0.5, 1.6, -0.12, "a column with water")
        return None
    if name == "cave":
        for (px, pz), v in by_near:
            if v > 20:
                return (px + 0.5, 12.01, pz + 0.5, 2.4, 0.55, "under the terrain")
        return None
    if name == "sky":
        (px, pz), top = max(land, key=lambda kv: kv[1])
        return (px + 0.5, top + 12.01, pz + 0.5, -1.2, -0.02, f"above the ground ({top})")
    if name == "edge":
        (px, pz), v = max(land, key=lambda kv: kv[0][0])
        return (px + 0.5, v + 1.01, pz + 0.5, -1.5708, -0.06, "the easternmost column")
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
