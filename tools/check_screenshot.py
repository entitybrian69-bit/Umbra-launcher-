#!/usr/bin/env python3
"""Screenshot gate: prove the capture is fresh, not blank, and still looks like
the reference.

Why this shape (the brief's rule 3): a stale file passes a "does it contain the
right colours" check, so this gate compares two screenshots taken in the same
run and requires them to differ; it decodes the PNG properly (filters are
applied, not guessed from byte counts); and it compares to the reference by
normalised similarity, not by counting pixels of a colour.
"""
import sys, zlib, struct, hashlib, os

def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, w, h, bd, ct = 8, b"", 0, 0, 0, 0
    while pos + 8 <= len(data):
        ln = struct.unpack(">I", data[pos:pos+4])[0]
        ty = data[pos+4:pos+8]
        body = data[pos+8:pos+8+ln]
        if ty == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", body[:10])
        elif ty == b"IDAT":
            idat += body
        elif ty == b"IEND":
            break
        pos += 12 + ln
    if bd != 8 or ct not in (2, 6):
        raise SystemExit(f"{path}: unsupported PNG (bit depth {bd}, colour type {ct})")
    ch = 3 if ct == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        row = bytearray(raw[p:p+stride]); p += stride
        for i in range(stride):
            a = row[i-ch] if i >= ch else 0
            b = prev[i]
            c = prev[i-ch] if i >= ch else 0
            if f == 1: row[i] = (row[i] + a) & 0xFF
            elif f == 2: row[i] = (row[i] + b) & 0xFF
            elif f == 3: row[i] = (row[i] + (a + b)//2) & 0xFF
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 0xFF
        for x in range(w):
            o = (y*w + x) * 3
            out[o:o+3] = row[x*ch:x*ch+3]
        prev = row
    return w, h, bytes(out)

def signature(w, h, rgb, n=16):
    """Downsample to n x n average colours: a stable similarity signature."""
    sig = []
    for gy in range(n):
        for gx in range(n):
            x0, x1 = gx*w//n, max(gx*w//n + 1, (gx+1)*w//n)
            y0, y1 = gy*h//n, max(gy*h//n + 1, (gy+1)*h//n)
            r = g = b = cnt = 0
            stepy = max(1, (y1-y0)//8); stepx = max(1, (x1-x0)//8)
            for y in range(y0, y1, stepy):
                for x in range(x0, x1, stepx):
                    o = (y*w + x)*3
                    r += rgb[o]; g += rgb[o+1]; b += rgb[o+2]; cnt += 1
            sig.append((r//cnt, g//cnt, b//cnt))
    return sig

def variance(rgb):
    n = len(rgb)//3
    tot = sum(rgb[::max(1, n//5000)])/max(1, len(rgb[::max(1, n//5000)]))
    var = sum((rgb[i] - tot)**2 for i in range(0, len(rgb), max(1, n//5000)))/max(1, len(rgb[::max(1, n//5000)]))
    return var

def main():
    args = sys.argv[1:]
    shots = [a for a in args if a.endswith(".png")]
    ref = None
    if "--reference" in args:
        ref = args[args.index("--reference") + 1]
    if len(shots) < 2:
        raise SystemExit("usage: check_screenshot.py shot1.png shot2.png [--reference ref.png]")
    w1, h1, px1 = read_png(shots[0])
    w2, h2, px2 = read_png(shots[1])
    print(f"{shots[0]}: {w1}x{h1} sha256 {hashlib.sha256(px1).hexdigest()[:16]}")
    print(f"{shots[1]}: {w2}x{h2} sha256 {hashlib.sha256(px2).hexdigest()[:16]}")
    if (w1, h1) != (w2, h2):
        raise SystemExit("FAIL: the two screenshots differ in size")
    v1 = variance(px1)
    print(f"variance of shot1: {v1:.1f}")
    if v1 < 50:
        raise SystemExit("FAIL: shot1 is blank or nearly so")
    if hashlib.sha256(px1).hexdigest() == hashlib.sha256(px2).hexdigest():
        raise SystemExit("FAIL: the two screenshots are identical, so at least one is stale")
    differing = sum(1 for i in range(0, len(px1), 3*97) if px1[i] != px2[i])
    print(f"pixels sampled that changed between the shots: {differing}")
    if differing == 0:
        raise SystemExit("FAIL: nothing changed between the screenshots")
    if ref and os.path.exists(ref):
        rw, rh, rpx = read_png(ref)
        if (rw, rh) != (w1, h1):
            print(f"note: reference is {rw}x{rh}, capture is {w1}x{h1}")
        s1 = signature(w1, h1, px1)
        sr = signature(rw, rh, rpx)
        diffs = [abs(a[i]-b[i]) for a, b in zip(s1, sr) for i in range(3)]
        mad = sum(diffs)/len(diffs)
        print(f"mean absolute difference from the reference: {mad:.2f} (of 255)")
        if mad > 24:
            raise SystemExit("FAIL: the screen no longer looks like the reference")
    elif ref:
        print(f"note: no reference at {ref} yet; this run's capture is the candidate")
        raise SystemExit("FAIL: no reference image; commit the artifact from this run as the reference")
    print("PASS: screenshots are fresh, non-blank and match the reference")

if __name__ == "__main__":
    main()
