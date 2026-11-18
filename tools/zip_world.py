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
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files:
            name = "region/" + os.path.basename(path)
            z.write(path, name)
            total += os.path.getsize(path)
            print(f"+ {name}: {os.path.getsize(path)} bytes")
    print(f"wrote {out}: {len(files)} region file(s), {total} bytes of regions, "
          f"{os.path.getsize(out)} bytes in the archive")
    return 0


if __name__ == "__main__":
    sys.exit(main())
