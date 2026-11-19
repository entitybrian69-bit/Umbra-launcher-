#!/usr/bin/env python3
"""A save whose window spans the origin, in four region files, for the streaming tests.

Why this exists separately from `gen_world_zip_fixture.py`: that fixture is two chunks in
`r.0.0.mca`, and every window it can hold is entirely inside one region file at
non-negative coordinates. A streaming reader has to do three things that fixture cannot
see:

  * put chunk **-1,-1** in region **-1,-1** -- the arithmetic that turns a chunk position
    into a region file and a local slot is where negative coordinates go wrong, and it is
    wrong silently: the read lands in a sector that holds some other chunk or nothing;
  * hold a window **across** the origin, so the resident set is not a block of the
    positive quadrant but a square centred on 0,0, exactly as the game's spawn is;
  * span **four region files at once**, so the reader has to pick a region per chunk
    instead of remembering the one it opened.

So this writes chunks -2..1 in x and z -- a 4x4 square across the origin -- split into
`r.-1.-1.mca`, `r.0.-1.mca`, `r.-1.0.mca` and `r.0.0.mca`, each holding the 2x2 of chunks
that belongs to it. The chunks come from the same Anvil writer as every other fixture
(`make_test_world.write_chunk`), so what the tests read is a world two implementations
already agree on; nothing here is a second opinion about the format.

The height of every chunk is a function of its chunk position, so a block read from a
wrong chunk is a block with the wrong height -- a test can tell "this chunk is here" from
"some chunk is here", which a fixture of identical chunks cannot.

usage: tools/gen_stream_world.py [out dir]
"""
import os
import sys
import zipfile

HERE = os.path.abspath(os.path.dirname(__file__))
sys.path.insert(0, HERE)
import make_test_world  # noqa: E402

BASE = os.path.abspath(os.path.join(HERE, "..", "goose", "test", "fixtures", "worldstream"))


def columns():
    """The chunk positions in the fixture, and the surface height of each.

    Heights are deliberately distinct per chunk: a test that reads the wrong chunk reads
    a wrong height, and a test that hashes geometry reads a different hash.
    """
    out = {}
    for cz in range(-2, 2):
        for cx in range(-2, 2):
            # 60 + a number that is unique to this chunk, so no two chunks are alike.
            out[(cx, cz)] = 60 + ((cx + 2) * 4 + (cz + 2))
    return out


def chunk_nbt(cx: int, cz: int, height: int) -> bytes:
    """One chunk: stone up to `height`, dirt under the grass, grass on top."""
    cells = {}
    for x in range(16):
        for z in range(16):
            for wy in range(40, height):
                if wy < height - 3:
                    state = {"Name": "minecraft:stone"}
                elif wy < height - 1:
                    state = {"Name": "minecraft:dirt"}
                else:
                    state = {"Name": "minecraft:grass_block",
                             "Properties": {"snowy": "false"}}
                cells[(x, wy, z)] = state
    sections = []
    for y in range(-4, 6):
        extra = {}
        for (x, wy, z), state in cells.items():
            if wy // 16 != y:
                continue
            extra[(x, wy - y * 16, z)] = state
        if not extra:
            continue
        sections.append(make_test_world.section(y, "minecraft:air", extra))
    return make_test_world.chunk(cx, cz, 4189, sections)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else BASE
    os.makedirs(out, exist_ok=True)
    heights = columns()
    # Region -> its chunks, as {local (0..31): nbt}. Only 4 of 32 slots are used per file,
    # which is what makes the sparse read path (an empty location) part of the test too.
    regions = {}
    for (cx, cz), height in heights.items():
        rx = -1 if cx < 0 else 0
        rz = -1 if cz < 0 else 0
        lx = cx - rx * 32
        lz = cz - rz * 32
        regions.setdefault((rx, rz), {})[(lx, lz)] = chunk_nbt(cx, cz, height)
    save = os.path.join(out, "save")
    region_dir = os.path.join(save, "region")
    os.makedirs(region_dir, exist_ok=True)
    for (rx, rz), chunks in sorted(regions.items()):
        name = f"r.{rx}.{rz}.mca"
        with open(os.path.join(region_dir, name), "wb") as f:
            f.write(make_test_world.region(chunks))
        print(f"wrote {name}: {len(chunks)} chunk(s)")
    with open(os.path.join(save, "level.dat"), "wb") as f:
        f.write(b"\x0a" + make_test_world.struct.pack(">H", 0) + make_test_world.t_compound([
            make_test_world.tag(10, "Data", make_test_world.t_compound([
                make_test_world.tag(3, "version", make_test_world.t_int(19133))])),
        ]))

    # The archive the app would receive: the same region files, under the classic path.
    # The build step zips `region/*.mca` and nothing else (see tools/zip_world.py), and so
    # does this: a fixture that includes level.dat would be testing a different importer.
    zip_path = os.path.join(out, "world-stream.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(region_dir)):
            z.write(os.path.join(region_dir, name), f"region/{name}")
    print(f"wrote {zip_path}")
    print("heights: " + ", ".join(f"{cx},{cz}={h}" for (cx, cz), h in sorted(heights.items())))


if __name__ == "__main__":
    main()
