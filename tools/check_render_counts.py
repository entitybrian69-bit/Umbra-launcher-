#!/usr/bin/env python3
"""Read a `jr:` render log and check the counts that decide whether a picture means anything.

usage: tools/check_render_counts.py <log> [--min-blocks N]

Why this is separate from the shell: the numbers are the evidence, and an evidence line
that nothing parses is decoration. Two of them decide whether "a world drawn with the jar"
is true:

  * `blocks whose blockstate had no model` - a block with no model is drawn as nothing, so
    a world can look plausible while quietly missing its trees, its slabs or its water;
  * `blocks drawn from a model` - a world of four chunks is tens of thousands of faces; a
    few hundred means the blockstates stopped matching.

It also prints the texture numbers, because a missing texture is a magenta tile in the
picture and a count in the log, and the count is easier to act on.
"""
import re
import sys

DEFAULT_MIN_BLOCKS = 1000


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = args[0]
    min_blocks = DEFAULT_MIN_BLOCKS
    if "--min-blocks" in args:
        min_blocks = int(args[args.index("--min-blocks") + 1])

    text = open(path, errors="replace").read()

    m = re.search(r"jr: blocks drawn from a model (\d+), faces (\d+), "
                  r"blocks whose blockstate had no model (\d+)", text)
    if not m:
        print(f"FAIL: {path} has no model counts: nothing proved the world was modelled")
        return 1
    blocks, faces, missing = (int(m.group(i)) for i in (1, 2, 3))
    print(f"render counts: {blocks} blocks drawn from a model, {faces} faces, "
          f"{missing} blocks with no model")

    t = re.search(r"jr: textures used (\d+), decoded (\d+), missing (\d+), animated (\d+)", text)
    if t:
        print(f"render textures: {t.group(1)} used, {t.group(2)} decoded, "
              f"{t.group(3)} missing, {t.group(4)} animated")

    s = re.search(r"jr: save (\d+) region file\(s\), (\d+) chunks, (\d+) non-air blocks, "
                  r"(\d+) read error", text)
    if s:
        print(f"render save: {s.group(1)} region file(s), {s.group(2)} chunks, "
              f"{s.group(3)} non-air blocks, {s.group(4)} read errors")
        if int(s.group(4)) != 0:
            print("FAIL: some chunks of the save could not be read")
            return 1

    failures = 0
    if missing != 0:
        print(f"FAIL: {missing} blocks of the loaded world have no model in the jar")
        failures += 1
    if blocks < min_blocks:
        print(f"FAIL: only {blocks} blocks came from a model (expected at least {min_blocks})")
        failures += 1
    if "jr: PASS - a world drawn with the jar's own models and textures" not in text:
        print("FAIL: the renderer did not say it drew the world")
        failures += 1
    if failures:
        return 1
    print("PASS: every block of the loaded world came from its own model in the jar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
