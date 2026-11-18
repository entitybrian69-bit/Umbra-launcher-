#!/usr/bin/env python3
"""A `.zip` of a world, for the app's world-import test.

Question (c) of the brief: does the phone open a world the game generated? The thing a
phone can receive is one file, so what it imports is a zip of a save's `region/`
directory. This writes that archive -- from the same Anvil writer the reader's tests
already use (`tools/make_test_world.py`), so the archive's chunks are a world two
independent implementations agree on -- plus the things a real save holds in the same
directory that are *not* blocks (`level.dat`), so the importer's "which entry is a
region file" rule is tested against a file that looks like a world and is not one.

Two archives are written:

  world-classic.zip   region/r.0.0.mca plus level.dat, the layout a save exported from
                      the game has.
  world-modern.zip    the same bytes under dimensions/minecraft/overworld/region/, which
                      is where 26.3 keeps the overworld. An importer that only knew one
                      of the two layouts would open one version of the game's saves and
                      silently refuse the other.
  world-not-a-world.zip  a zip with a level.dat and no region file, which the importer
                      must refuse with a sentence instead of an empty world.
  world-no-blocks.zip    region files of the kind a save keeps in `entities/`: chunks that
                      parse, with no blocks in them. The importer must refuse this too --
                      it was reported as an opened world once.
  world-263-status.zip   a complete save whose chunks spell the status field `status`,
                      as 26.3 does. The importer must count zero unfinished chunks.

usage: tools/gen_world_zip_fixture.py [out dir] [chunks]
"""
import os
import sys
import zipfile

HERE = os.path.abspath(os.path.dirname(__file__))
sys.path.insert(0, HERE)
import make_test_world  # noqa: E402

BASE = os.path.abspath(os.path.join(HERE, "..", "goose", "test", "fixtures", "worldzip"))


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else BASE
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    work = os.path.join(out, "save")
    os.makedirs(out, exist_ok=True)
    make_test_world.build(work, count)
    regions = []
    for name in sorted(os.listdir(os.path.join(work, "region"))):
        with open(os.path.join(work, "region", name), "rb") as f:
            regions.append((name, f.read()))
    with open(os.path.join(work, "level.dat"), "rb") as f:
        level = f.read()
    print(f"source: {len(regions)} region file(s), level.dat {len(level)} bytes")

    # The same bytes under the 26.3 overworld path, so the test's directory read of the
    # modern archive has a directory to read.
    modern_dir = os.path.join(work, "dimensions", "minecraft", "overworld", "region")
    os.makedirs(modern_dir, exist_ok=True)
    for name, data in regions:
        with open(os.path.join(modern_dir, name), "wb") as f:
            f.write(data)

    classic = os.path.join(out, "world-classic.zip")
    with zipfile.ZipFile(classic, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in regions:
            z.writestr("region/" + name, data)
        z.writestr("level.dat", level)
    print(f"wrote {classic} ({os.path.getsize(classic)} bytes)")

    modern = os.path.join(out, "world-modern.zip")
    with zipfile.ZipFile(modern, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in regions:
            z.writestr("dimensions/minecraft/overworld/region/" + name, data)
        z.writestr("level.dat", level)
    print(f"wrote {modern} ({os.path.getsize(modern)} bytes)")

    notworld = os.path.join(out, "world-not-a-world.zip")
    with zipfile.ZipFile(notworld, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("level.dat", level)
        z.writestr("data/chunks.dat", b"\x0a\x00\x00")
    print(f"wrote {notworld} ({os.path.getsize(notworld)} bytes)")

    # A save's other region directory: `entities/r.0.0.mca`, beside `region/r.0.0.mca` and
    # with the same file name. Its chunks hold entity NBT, not block states -- so a chunk
    # reader accepts the envelope, finds a palette, and counts no blocks at all. On
    # 2026-11-18 run 44251941145 zipped exactly these files and the phone reported "25
    # chunks, 600 states, non-air blocks 0" and drew nothing, which is why the importer now
    # refuses a world with no blocks in it. This archive is that mistake, kept.
    entities = os.path.join(work, "dimensions", "minecraft", "overworld", "entities")
    os.makedirs(entities, exist_ok=True)
    empty_chunk = make_test_world.chunk(0, 0, 3837, [])
    ent_region = make_test_world.region({(0, 0): empty_chunk, (1, 0): empty_chunk})
    # A save written by 26.3, which spells the chunk's status field `status` where older
    # versions wrote `Status` -- the same rename as `properties`. This archive is complete
    # by every other measure: full terrain, minecraft:full in the field that exists, a
    # status field at all. The only thing wrong with it is the spelling, and a reader that
    # knows one spelling calls every chunk unfinished. Run 44279451494: 529 chunks, 844 904
    # non-air blocks, 44 states, "528 of 529 chunks are not minecraft:full yet".
    modern_spelling = os.path.join(work, "modern-spelling")
    make_test_world.build(modern_spelling, count, "status")
    modern_regions = []
    for name in sorted(os.listdir(os.path.join(modern_spelling, "region"))):
        with open(os.path.join(modern_spelling, "region", name), "rb") as f:
            modern_regions.append((name, f.read()))
    spelled = os.path.join(out, "world-263-status.zip")
    with zipfile.ZipFile(spelled, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in modern_regions:
            z.writestr("region/" + name, data)
        z.writestr("level.dat", level)
    print(f"wrote {spelled} ({os.path.getsize(spelled)} bytes)")

    noblocks = os.path.join(out, "world-no-blocks.zip")
    with zipfile.ZipFile(noblocks, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("dimensions/minecraft/overworld/entities/r.0.0.mca", ent_region)
        z.writestr("level.dat", level)
    print(f"wrote {noblocks} ({os.path.getsize(noblocks)} bytes)")


if __name__ == "__main__":
    main()
