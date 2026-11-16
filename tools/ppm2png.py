#!/usr/bin/env python3
"""P6 PPM to RGB PNG, and back, with nothing but zlib.

The renderer writes PPM because that is nine lines of C-free code in Goose; the
evidence, the reference and the similarity check all want a PNG. Keeping the
conversion here means the check runs anywhere Python does.

usage: tools/ppm2png.py <in.ppm> <out.png>
       tools/ppm2png.py --png2ppm <in.png> <out.ppm>
"""
import struct
import sys
import zlib


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def ppm_to_png(src: str, dst: str) -> None:
    data = open(src, "rb").read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{src}: not a P6 PPM")
    fields = []
    i = 2
    while len(fields) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while i < len(data) and data[i] != 0x0A:
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1
    w, h, maxv = fields
    if maxv != 255:
        raise SystemExit(f"{src}: only 8-bit PPM is supported")
    px = data[i:i + w * h * 3]
    if len(px) != w * h * 3:
        raise SystemExit(f"{src}: short pixel data")
    raw = b"".join(b"\x00" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))
    open(dst, "wb").write(b"\x89PNG\r\n\x1a\n"
                          + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                          + _chunk(b"IDAT", zlib.compress(raw, 6))
                          + _chunk(b"IEND", b""))


def png_to_rgb(src: str):
    data = open(src, "rb").read()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"{src}: not a PNG")
    i = 8
    w = h = depth = ctype = -1
    idat = b""
    while i + 8 <= len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        i += 12 + n
    if depth != 8 or ctype not in (2, 6):
        raise SystemExit(f"{src}: only 8-bit RGB/RGBA PNG is supported")
    step = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * step
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        for x in range(stride):
            a = line[x - step] if x >= step else 0
            b = prev[x]
            c = prev[x - step] if x >= step else 0
            if f == 1:
                line[x] = (line[x] + a) & 0xFF
            elif f == 2:
                line[x] = (line[x] + b) & 0xFF
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
            elif f != 0:
                raise SystemExit(f"{src}: bad filter {f}")
        for x in range(w):
            out[(y * w + x) * 3:(y * w + x) * 3 + 3] = line[x * step:x * step + 3]
        prev = line
    return w, h, bytes(out)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--png2ppm":
        w, h, rgb = png_to_rgb(sys.argv[2])
        with open(sys.argv[3], "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w, h))
            f.write(rgb)
    elif len(sys.argv) == 3:
        ppm_to_png(sys.argv[1], sys.argv[2])
    else:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
