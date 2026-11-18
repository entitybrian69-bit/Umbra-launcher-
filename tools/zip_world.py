#!/usr/bin/env python3
"""Zip a save's region files into the archive the phone's world import opens.

The phone cannot be handed a directory: the file picker hands over one document, and the
app's own directory holds one file. So the archive is the format, and this makes one out
of region files the real server wrote -- `region/r.<x>.<z>.mca` at the top of the
archive, which is what a save exported from the game looks like and what
`core/worldload_in.goose` looks for.

usage: tools/zip_world.py <out.zip> <region file> [region file ...]
"""
import os
import sys
import zipfile


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = sys.argv[1]
    files = sys.argv[2:]
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    total = 0
    # An entities file is not a region file. They share a name and a location pattern
    # (`entities/r.0.0.mca` beside `region/r.0.0.mca`) and contain entity NBT, so a zip
    # built from them opens as a world with chunks and no blocks. Run 44251941145 did
    # exactly that. Refusing here means the mistake cannot reach a phone.
    wrong = [f for f in files if os.path.basename(os.path.dirname(f)) != "region"]
    if wrong:
        for f in wrong:
            print(f"not a region file (its directory is not 'region/'): {f}", file=sys.stderr)
        return 1
    # Two region files that differ only by the directory they are in become the same entry
    # in the archive, and zipfile keeps the *last* one. Run 44285758258 handed the phone two
    # overworld layouts -- `world/region/r.0.0.mca`, left over from spawn preparation, and
    # `world/dimensions/minecraft/overworld/region/r.0.0.mca`, the real terrain -- and the
    # stale one won on sort order. The phone reported 25 chunks, 600 states and 0 blocks:
    # proto-chunks, exactly what an empty layout looks like. Refusing here means the choice
    # has to be made on purpose, by whoever calls this.
    seen = {}
    clashes = []
    for path in files:
        name = os.path.basename(path)
        if name in seen:
            clashes.append((name, seen[name], path))
        else:
            seen[name] = path
    if clashes:
        for name, first, second in clashes:
            print(f"two region files would become region/{name} in the archive:\n"
                  f"  {first}\n  {second}\n"
                  f"pick one layout before zipping", file=sys.stderr)
        return 1
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            name = "region/" + os.path.basename(path)
            z.write(path, name)
            total += os.path.getsize(path)
            print(f"+ {name}: {os.path.getsize(path)} bytes")
    print(f"wrote {out}: {len(files)} region file(s), {total} bytes of regions, "
          f"{os.path.getsize(out)} bytes in the archive")
    return 0


def selftest() -> int:
    """Prove the two rules that two red runs taught, without a Minecraft server."""
    import tempfile

    def mk(root, sub, name):
        d = os.path.join(root, sub, "region")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "wb") as f:
            f.write(b"x" * 8)
        return p

    with tempfile.TemporaryDirectory() as tmp:
        legacy = mk(tmp, "world", "r.0.0.mca")
        modern = mk(tmp, "world/dimensions/minecraft/overworld", "r.0.0.mca")
        out = os.path.join(tmp, "w.zip")
        # 1. Two layouts, same name: refused. Run 44285758258 zipped both and the stale one
        #    won, which the phone reported as "25 chunks, 0 non-air blocks".
        if _quiet(out, [legacy, modern]) == 0:
            print("the duplicate check did not fire", file=sys.stderr)
            return 1
        # 2. One layout: accepted, and the entry is region/<name>.
        if _quiet(out, [modern]) != 0:
            print("the single-layout zip was refused", file=sys.stderr)
            return 1
        with zipfile.ZipFile(out) as z:
            names = z.namelist()
        if names != ["region/r.0.0.mca"]:
            print(f"unexpected archive contents: {names}", file=sys.stderr)
            return 1
        # 3. An entities file is still refused.
        ent = os.path.join(tmp, "world", "entities", "r.0.0.mca")
        os.makedirs(os.path.dirname(ent), exist_ok=True)
        open(ent, "wb").close()
        if _quiet(out, [ent]) == 0:
            print("an entities file was accepted as a region file", file=sys.stderr)
            return 1
    print("zip_world selftest: 3 checks")
    return 0


def _quiet(out, files):
    saved, sys.argv = sys.argv, ["zip_world.py", out] + files
    saved_out = sys.stdout
    class _Sink:
        def write(self, *_a): pass
        def flush(self): pass
    try:
        sys.stdout = _Sink()
        return main()
    finally:
        sys.stdout = saved_out
        sys.argv = saved


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
