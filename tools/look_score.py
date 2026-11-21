#!/usr/bin/env python3
"""How close does Umbra's world look to the reference picture?

Step 4 of the owner's plan asks for the look (biome tints, stored light, face shading, sky and
fog, translucent water) and forbids claiming visual parity without a score. This is the score.

It is deliberately the same measure the screenshot gate already uses -- a 32x32 grid of average
colours, compared by mean absolute difference out of 255 -- with two things the gate does not
need and this does:

  * the **HUD band is cropped**. The overlay covers the top of the phone's screen and the
    reference has no overlay; scoring the panel against sky would measure the two layouts, not
    the two world renderings.
  * a **per-region breakdown**: sky, ground and the whole frame are scored separately, because
    a good average can hide a sky that is the wrong blue or water that is not translucent, and
    those are exactly what step 4 is about.

Usage:
  tools/look_score.py capture.png --reference ref.png [--crop-top PIXELS] [--json]

Exit status is 0 whenever it printed a score. A threshold belongs to whoever compares two
builds; this tool's job is to make the comparison possible and honest.
"""
import sys, zlib, struct, json

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
        out[y*3*w:(y+1)*3*w] = bytes(row[x*ch:x*ch+3] for x in range(0)) or b""
        for x in range(w):
            o = (y*w + x) * 3
            out[o:o+3] = row[x*ch:x*ch+3]
        prev = row
    return w, h, bytes(out)

def grid_sig(w, h, rgb, n=32):
    """n x n average colours. Same shape as the screenshot gate's signature, denser."""
    sig = []
    for gy in range(n):
        for gx in range(n):
            x0, x1 = gx*w//n, max(gx*w//n + 1, (gx+1)*w//n)
            y0, y1 = gy*h//n, max(gy*h//n + 1, (gy+1)*h//n)
            r = g = b = cnt = 0
            stepy = max(1, (y1-y0)//10); stepx = max(1, (x1-x0)//10)
            for y in range(y0, y1, stepy):
                for x in range(x0, x1, stepx):
                    o = (y*w + x)*3
                    r += rgb[o]; g += rgb[o+1]; b += rgb[o+2]; cnt += 1
            sig.append((r//cnt, g//cnt, b//cnt))
    return sig

def band_sig(w, h, rgb, y0frac, y1frac, n=32):
    """The signature of a horizontal band of the image, resampled to n rows."""
    sig = []
    for gy in range(n):
        y0 = int(h * (y0frac + (y1frac - y0frac) * gy / n))
        y1 = max(y0 + 1, int(h * (y0frac + (y1frac - y0frac) * (gy + 1) / n)))
        for gx in range(n):
            x0, x1 = gx*w//n, max(gx*w//n + 1, (gx+1)*w//n)
            r = g = b = cnt = 0
            for y in range(y0, y1, max(1, (y1-y0)//10)):
                for x in range(x0, x1, max(1, (x1-x0)//10)):
                    o = (y*w + x)*3
                    r += rgb[o]; g += rgb[o+1]; b += rgb[o+2]; cnt += 1
            sig.append((r//cnt, g//cnt, b//cnt))
    return sig

def mad(a, b):
    diffs = [abs(x[i]-y[i]) for x, y in zip(a, b) for i in range(3)]
    return sum(diffs)/len(diffs)

def main():
    args = sys.argv[1:]
    if not args or "--reference" not in args:
        raise SystemExit("usage: look_score.py capture.png --reference ref.png [--crop-top N] [--json]")
    cap = args[0]
    ref = args[args.index("--reference") + 1]
    # Fractions, for a crop that is a share of the screen rather than a number of pixels: the
    # overlay panel may take up to 45% of the height (umbra_hud.h's own limit) and the button
    # row 8%, and that stays true on a phone that is not 1080 rows tall.
    cw0, ch0, _cpx0 = read_png(cap)
    crop_top = int(args[args.index("--crop-top") + 1]) if "--crop-top" in args else 0
    crop_bottom = int(args[args.index("--crop-bottom") + 1]) if "--crop-bottom" in args else 0
    if "--crop-top-frac" in args:
        crop_top = int(round(ch0 * float(args[args.index("--crop-top-frac") + 1])))
    if "--crop-bottom-frac" in args:
        crop_bottom = int(round(ch0 * float(args[args.index("--crop-bottom-frac") + 1])))
    # The reference needs its own crop when the two frames put the horizon in different
    # places. The phone's overlay buttons sit along the bottom of the capture and nothing
    # sits there in the reference; the overlay panel sits along the *top* of the capture
    # and there is no panel in the reference either. Cropping the same number of rows off
    # both would compare the capture's ground against the reference's sky.
    ref_crop_top = int(args[args.index("--reference-crop-top") + 1]) \
        if "--reference-crop-top" in args else 0
    ref_crop_bottom = int(args[args.index("--reference-crop-bottom") + 1]) \
        if "--reference-crop-bottom" in args else 0

    cw, chh, cpx = read_png(cap)
    rw, rh, rpx = read_png(ref)
    cpx_uncropped = cpx
    # Crop the HUD off the top of the capture, in pixels, then treat the remainder as the frame.
    # Both ends: the overlay is a panel across the top and a row of buttons along the bottom,
    # and the reference has neither. Cropping only the top scored the buttons against terrain
    # and reported 36.34 where the world itself is closer than that.
    if crop_top or crop_bottom:
        keep = chh - crop_top - crop_bottom
        if keep < 8:
            raise SystemExit(f"{cap}: cropping {crop_top}+{crop_bottom} of {chh} rows leaves nothing")
        stride = cw * 3
        cpx = b"".join(cpx[(crop_top + y)*stride:(crop_top + y + 1)*stride] for y in range(keep))
        chh = keep

    if ref_crop_top or ref_crop_bottom:
        keep = rh - ref_crop_top - ref_crop_bottom
        if keep < 8:
            raise SystemExit(f"{ref}: cropping {ref_crop_top}+{ref_crop_bottom} of {rh} rows leaves nothing")
        stride = rw * 3
        rpx = b"".join(rpx[(ref_crop_top + y)*stride:(ref_crop_top + y + 1)*stride] for y in range(keep))
        rh = keep

    # The one comparison that proves the machinery is right: an image against itself after the
    # same crop must be exactly zero. It was not, the first time this ran -- the crop was
    # applied to the capture and not to the reference, which measured 38.51 of 255 against
    # itself and would have made every score a number about the crop.
    self_mad = mad(grid_sig(cw, chh, cpx), grid_sig(cw, chh, cpx))
    if self_mad != 0.0:
        raise SystemExit(f"look: FAIL -- a frame scored {self_mad:.2f} against itself")
    # The crop's own proof, against the only thing that cannot lie about it: the same rows
    # taken out of the file before the tool sees it. Applied to the capture and then scored
    # with no flags, both paths must produce the identical grid. This is not paranoia --
    # the first version cropped one buffer with the other's stride and scored 38.51 against
    # itself, and a later one compared the cropped height against the crop again and
    # refused every image that had one.
    if crop_top or crop_bottom:
        # Slice the *uncropped* rows directly, the way another PNG writer would.
        stride = cw * 3
        ref_slice = b"".join(cpx_uncropped[(crop_top + y)*stride:(crop_top + y + 1)*stride]
                             for y in range(ch0 - crop_top - crop_bottom))
        a = grid_sig(cw, ch0 - crop_top - crop_bottom, ref_slice)
        b = grid_sig(cw, chh, cpx)
        drift = mad(a, b)
        if drift != 0.0:
            raise SystemExit(f"look: FAIL -- the crop does not match the rows it kept "
                             f"({drift:.2f} of 255 apart)")

    # The same proof for each image's own crop: after cropping, the reference's grid must
    # still be a function of the reference alone. A crop applied to the wrong buffer (the
    # capture's bytes, the reference's stride) is exactly how the first version of this
    # scored 38.51 against itself, and the crops are now asymmetric, so an image is no
    # longer comparable with itself -- each one is checked on its own instead.
    if mad(grid_sig(rw, rh, rpx), grid_sig(rw, rh, rpx)) != 0.0:
        raise SystemExit(f"look: FAIL -- the cropped reference is not stable")
    # `chh` and `rh` were reduced by the crops above, so what is left is positive by
    # construction; the check that used to sit here compared the *cropped* heights against
    # the crops again and refused every image with a crop on it.
    whole = mad(grid_sig(cw, chh, cpx), grid_sig(rw, rh, rpx))
    # Sky is the top third, ground the bottom two thirds: the two things step 4 changes.
    sky = mad(band_sig(cw, chh, cpx, 0.0, 0.33), band_sig(rw, rh, rpx, 0.0, 0.33))
    ground = mad(band_sig(cw, chh, cpx, 0.33, 1.0), band_sig(rw, rh, rpx, 0.33, 1.0))

    # The fraction of the frame that is the reference's own horizon blue, in each. A cheap but
    # honest second opinion: if the sky is the wrong colour this moves even when the ground
    # does not, and it is not the same number as the band score above.
    def frac_horizon(w, h, rgb):
        hit = tot = 0
        for y in range(0, h, max(1, h//120)):
            for x in range(0, w, max(1, w//120)):
                o = (y*w + x)*3
                r, g, b = rgb[o], rgb[o+1], rgb[o+2]
                tot += 1
                if b > 150 and b > r + 25 and b > g + 10 and g > r:
                    hit += 1
        return hit / max(1, tot)
    ch_sky = frac_horizon(cw, chh, cpx)
    rh_sky = frac_horizon(rw, rh, rpx)

    out = {"capture": cap, "reference": ref, "crop_top": crop_top, "crop_bottom": crop_bottom,
           "reference_crop_top": ref_crop_top, "reference_crop_bottom": ref_crop_bottom,
           "whole_mad": round(whole, 2), "sky_mad": round(sky, 2), "ground_mad": round(ground, 2),
           "capture_sky_fraction": round(ch_sky, 3), "reference_sky_fraction": round(rh_sky, 3)}
    if "--json" in args:
        print(json.dumps(out, indent=2))
    else:
        how = []
        if crop_top: how.append(f"top {crop_top}")
        if crop_bottom: how.append(f"bottom {crop_bottom}")
        ref_how = []
        if ref_crop_top: ref_how.append(f"top {ref_crop_top}")
        if ref_crop_bottom: ref_how.append(f"bottom {ref_crop_bottom}")
        print(f"look: {cap} against {ref}"
              + (f" (capture cropped: {', '.join(how)} rows -- the overlay and the buttons)"
                 if how else "")
              + (f" (reference cropped: {', '.join(ref_how)} rows)" if ref_how else ""))
        print(f"look: whole frame {whole:.2f} of 255")
        print(f"look: sky (top third) {sky:.2f}, ground (the rest) {ground:.2f}")
        print(f"look: horizon-blue share {ch_sky:.1%} against the reference's {rh_sky:.1%}")
        print("look: both images were cropped to the same kind of frame; the numbers describe "
              "only what was left after the crops")
    return 0

if __name__ == "__main__":
    sys.exit(main())
