#!/usr/bin/env python3
"""Compare the jar-drawn world picture against its committed reference.

The renderer is deterministic, so this is not a "did anything change" check: it is
"does the picture drawn from *this* jar still look like the picture the gate was
written against". A jar that suddenly loses its block models or its textures, a
layout bug that moves texels to the wrong tile, a camera change that frames a wall of
rock: all of those move the signature and none of them are visible in a log line.

Similarity is the same one the device screenshot gate uses: downsample both pictures
to a 16x16 grid of average colours and compare the mean absolute difference.

usage: tools/check_world_shot.py <shot.png> [--reference ref.png] [--record]
       --record   write the shot to the reference path when that file does not exist
                  (first run: the picture from a real jar becomes the reference)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_screenshot import read_png, signature  # noqa: E402

MAX_MAD = 12.0   # of 255; the same picture from the same jar lands near 0


def main() -> int:
    args = sys.argv[1:]
    if not args or not args[0].endswith(".png"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    shot = args[0]
    ref = args[args.index("--reference") + 1] if "--reference" in args else None
    record = "--record" in args

    w, h, px = read_png(shot)
    print(f"{shot}: {w}x{h}")
    sig = signature(w, h, px)
    if len(set(sig)) < 8:
        print(f"FAIL: the picture is one flat colour in {len(set(sig))} of 256 cells")
        return 1

    if not ref:
        print("PASS: the picture has structure (no reference to compare with)")
        return 0
    if not os.path.exists(ref):
        if record:
            os.makedirs(os.path.dirname(ref) or ".", exist_ok=True)
            with open(shot, "rb") as src, open(ref, "wb") as dst:
                dst.write(src.read())
            print(f"note: no reference at {ref}; this run's picture is now the reference")
            print("PASS: reference recorded (the next run compares against it)")
            return 0
        print(f"FAIL: no reference at {ref} and --record was not given")
        return 1

    rw, rh, rpx = read_png(ref)
    if (rw, rh) != (w, h):
        print(f"note: the reference is {rw}x{rh} and this picture is {w}x{h}")
        print("FAIL: the picture size changed; the gate cannot compare the two")
        return 1
    rsig = signature(rw, rh, rpx)
    diffs = [abs(a[i] - b[i]) for a, b in zip(sig, rsig) for i in range(3)]
    mad = sum(diffs) / len(diffs)
    worst = max(diffs)
    print(f"mean absolute difference from the reference: {mad:.2f} of 255 "
          f"(worst cell channel {worst})")
    if mad > MAX_MAD:
        print(f"FAIL: the picture no longer matches the reference (limit {MAX_MAD})")
        return 1
    print("PASS: the jar-drawn world matches the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
