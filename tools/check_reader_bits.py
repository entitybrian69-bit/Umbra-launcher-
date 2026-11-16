#!/usr/bin/env python3
"""Does the world reader decode sections of every palette width?

usage: tools/check_reader_bits.py [--keep]

A section's palette decides how many bits an index takes: two entries fit in four bits
(where every packing agrees), twenty need five, forty need six -- and above four bits a
value runs on across a 64-bit word boundary. A reader that gets that wrong reads almost
every block as air and a few as the wrong block, which is what the real-world comparison
against the server was showing: nine tenths of the world missing and stone reported where
the game had none.

The fixture is written by the same independent Anvil writer the region fixtures use, so a
disagreement here is a disagreement with the format, not with another reader of this one.
"""
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_region_fixtures as g  # noqa: E402  (the project's own Anvil writer)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# width of the palette -> the names in it
WIDTHS = [2, 6, 20, 40]


def entries(n):
    if n == 2:
        return ["minecraft:air", "minecraft:stone"]
    return ["minecraft:air"] + [f"minecraft:w{n}_{k}" for k in range(1, n)]


def pick(n, i):
    """A repeating pattern that uses every entry and never lands the same twice in a row."""
    return 0 if i % 5 == 0 else 1 + (i * 7) % (n - 1)


def section_y(index):
    return -4 + index


def build_section(y, palette, indices):
    used = sorted(set(indices))
    bits = max(4, (len(used) - 1).bit_length())
    local = {gid: i for i, gid in enumerate(used)}
    packed = [local[i] for i in indices]
    pal = [g.state_tag(palette[i].split("[")[0],
                       {"axis": "y"} if "[" in palette[i] else {}) for i in used]
    bs = g.compound("block_states", [
        g.list_("palette", 10, pal),
        g.long_array("data", g.pack(packed, bits)),
    ])
    return g.payload_compound([g.byte("Y", y), bs])


def main() -> int:
    work = tempfile.mkdtemp(prefix="umbra-bits-")
    region_dir = os.path.join(work, "dimensions", "minecraft", "overworld", "region")
    os.makedirs(region_dir)

    expect = {}
    sections = []
    for index, width in enumerate(WIDTHS):
        palette = entries(width)
        indices = [pick(width, i) for i in range(4096)]
        y = section_y(index)
        sections.append(build_section(y, palette, indices))
        for i in range(4096):
            name = palette[indices[i]]
            if name == "minecraft:air":
                continue
            ly, rem = divmod(i, 256)
            lz, lx = divmod(rem, 16)
            expect[(lx, y * 16 + ly, lz)] = name

    chunk = g.compound("", [g.int_("DataVersion", 3955), g.int_("xPos", 0),
                            g.int_("zPos", 0), g.string("Status", "minecraft:full"),
                            g.list_("sections", 10, sections)])
    nbt = chunk
    with open(os.path.join(region_dir, "r.0.0.mca"), "wb") as f:
        data, _ = g.region({(0, 0): nbt})
        f.write(data)

    if not os.path.exists(os.path.join(ROOT, "build", "umbra_worldload")):
        print("check_bits: build/umbra_worldload is missing", file=sys.stderr)
        return 2
    dump = os.path.join(work, "dump.txt")
    out = subprocess.run([os.path.join(ROOT, "build", "umbra_worldload"), work, dump, "1"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stdout, out.stderr, sep="\n")
        print("FAIL: the reader did not read the fixture")
        return 1

    got = {}
    with open(dump) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 5 or parts[0] != "detail":
                continue
            name = parts[4].split("[")[0]
            got[(int(parts[1]), int(parts[2]), int(parts[3]))] = name

    # A second, independent reading of the same fixture: the Python oracle walks the
    # NBT itself, so a reader that unpacked a width wrongly cannot hide by agreeing with
    # itself.
    oracle = os.path.join(work, "oracle.txt")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "world_oracle.py"),
                    work, oracle, "1"], check=False, capture_output=True)
    if os.path.exists(oracle):
        cmp_out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "check_world.py"),
                                  dump, oracle], capture_output=True, text=True)
        last = [l for l in cmp_out.stdout.splitlines() if l.startswith(("PASS", "FAIL"))]
        print("bits: the oracle " + (last[-1] if last else "printed no verdict"))
        if cmp_out.returncode != 0:
            print(cmp_out.stdout)
            return 1

    print(f"bits: {len(expect)} blocks expected over palettes of {WIDTHS} entries, "
          f"{len(got)} read")
    missing = wrong = 0
    for key, name in expect.items():
        if key not in got:
            missing += 1
            if missing <= 5:
                print(f"bits: nothing read at {key[0]} {key[1]} {key[2]}, expected {name}")
        elif got[key] != name:
            wrong += 1
            if wrong <= 5:
                print(f"bits: read {got[key]} at {key[0]} {key[1]} {key[2]}, "
                      f"expected {name}")
    if missing == 0 and wrong == 0 and len(got) == len(expect):
        print(f"PASS: every block of every palette width was read back, "
              f"{len(expect)} of {len(expect)}")
        return 0
    print(f"FAIL: {missing} blocks missing, {wrong} wrong, {len(got)} read of "
          f"{len(expect)} expected")
    return 1


if __name__ == "__main__":
    sys.exit(main())
