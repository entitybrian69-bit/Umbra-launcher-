#!/usr/bin/env python3
"""Is this gallery screenshot a picture, and is it a *different* picture?

The gallery used to decide that with `stat -c%s` and a 20 000-byte threshold. Run
44938399066 failed on it -- "shot-hills.png is 14581 bytes, which is not a picture" --
and the file was a perfectly valid 1920x1080 PNG of a patch of sky. Two things were
wrong and only one of them was the pose:

  * a byte count is a proxy for content, and a frame that is mostly one colour compresses
    to almost nothing. A sky shot is *supposed* to compress well; the threshold was
    measuring how interesting the picture was, badly;
  * six pictures of the same nothing would have passed it, so the gallery could not tell
    six poses from one pose taken six times.

So this decodes the PNG (filters applied, not guessed from the file size), requires the
surface the app is actually drawing on, requires more than a couple of colours, and -- when
`--differs-from` names the previous pose's shot -- requires the two not to be near
identical. A pose that failed to take is then a *failed pose*, not a small file.

There is a third thing a byte count cannot see: a frame that is one flat colour. That is
what 14 581 bytes actually meant -- the camera was in the open at y 320 over a save whose
ground stops at y 91, and the renderer had drawn the sky correctly. So the shot must hold
more than one colour across its whole width, which a correctly posed camera on any of the
six poses does.

usage: tools/check_gallery_shot.py <shot.png> [--differs-from OTHER.png]... [--min-colours 6]
                                   [--size WxH] [--flat-limit 0.985]
exit 0 = the shot is a picture of the right size, 1 = it is not, 2 = usage.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_screenshot import read_png, signature  # noqa: E402

# How far one average-colour cell has to move before two shots count as different pictures,
# summed over the signature's 16x16 cells. Two frames of the same pose that differ only in
# noise are well under this; two poses in different places are far over it.
DIFF_SUM = 60


def flat_share(w, h, rgb, stride=7):
    """How much of the frame one colour covers, sampled -- the "did it draw anything" test.

    The gallery's overlay is off, so a posed frame holds the world: terrain, sky, fog. A
    frame whose colour is one value from edge to edge is a camera pointed at nothing, which
    is a pose that went wrong, and the byte count cannot tell the two apart.
    """
    counts = {}
    total = 0
    for y in range(0, h, stride):
        base = y * w * 3
        for x in range(0, w, stride):
            o = base + x * 3
            key = rgb[o:o + 3]
            counts[key] = counts.get(key, 0) + 1
            total += 1
    return max(counts.values()) / total if total else 1.0


def distinct_colours(w, h, rgb, stride=13):
    seen = set()
    for y in range(0, h, stride):
        base = y * w * 3
        for x in range(0, w, stride):
            o = base + x * 3
            seen.add(rgb[o:o + 3])
    return len(seen)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    shot = argv[1]
    others = [argv[i + 1] for i, a in enumerate(argv) if a == "--differs-from"]
    flat_limit = float(argv[argv.index("--flat-limit") + 1]) if "--flat-limit" in argv else 0.985
    min_colours = int(argv[argv.index("--min-colours") + 1]) if "--min-colours" in argv else 6
    size = argv[argv.index("--size") + 1] if "--size" in argv else None

    try:
        w, h, rgb = read_png(shot)
    except OSError as e:
        print(f"{shot}: {e}", file=sys.stderr)
        return 2
    colours = distinct_colours(w, h, rgb)
    if size:
        want_w, want_h = (int(v) for v in size.lower().split("x"))
        if (w, h) != (want_w, want_h):
            print(f"{shot}: {w}x{h} is not the {want_w}x{want_h} surface the app drew on",
                  file=sys.stderr)
            return 1
    if colours < min_colours:
        print(f"{shot}: {w}x{h} with {colours} distinct colour(s) is a blank frame, not a picture",
              file=sys.stderr)
        return 1

    share = flat_share(w, h, rgb)
    if share > flat_limit:
        print(f"{shot}: {share:.1%} of the frame is one colour (limit {flat_limit:.1%}), so the "
              f"pose is looking at nothing -- this is a blank frame whether or not it is a "
              f"valid PNG", file=sys.stderr)
        return 1

    line = f"{os.path.basename(shot)}: {w}x{h}, {colours} distinct colour(s), one colour covers {share:.1%}"
    mine = signature(w, h, rgb)
    for other in others:
        w2, h2, rgb2 = read_png(other)
        if (w2, h2) != (w, h):
            print(f"{shot}: {w2}x{h2} differs in size from {other}, which cannot be a pose "
                  f"difference", file=sys.stderr)
            return 1
        a, b = mine, signature(w2, h2, rgb2)
        diff = sum(abs(p - q) for ca, cb in zip(a, b) for p, q in zip(ca, cb))
        if diff < DIFF_SUM:
            print(f"{shot}: this shot and {other} are the same picture (signature distance "
                  f"{diff} < {DIFF_SUM}), so one of the two poses drew nothing new",
                  file=sys.stderr)
            return 1
        line += f", {diff} from {os.path.basename(other)}"
    print("ok: " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
