#!/usr/bin/env python3
"""Fixtures for the Goose zip and PNG readers, built with Python's zlib.

zip: files are written with Python's zipfile at several compression levels and
one stored entry, plus a broken copy (flipped CRC) that the reader must reject.
png: images are written by a tiny independent PNG writer below, one per colour
type and filter, plus an interlaced and a corrupt one. The reader's RGBA output
is compared against expected RGBA written here.
"""
import hashlib
import json
import os
import struct
import zlib
import zipfile

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "goose", "test", "fixtures"))
ZIP_DIR = os.path.join(BASE, "zip")
PNG_DIR = os.path.join(BASE, "png")


def make_zip():
    os.makedirs(ZIP_DIR, exist_ok=True)
    payloads = {
        "assets/minecraft/textures/block/stone.png": bytes(range(256)) * 13,
        "assets/minecraft/blockstates/stone.json": b'{"variants":{"":{"model":"minecraft:block/stone"}}}',
        "data/minecraft/recipe/stick.json": b'{"type":"minecraft:crafting_shaped"}',
        "empty.txt": b"",
        "big.bin": bytes((i * 37) & 0xFF for i in range(70000)),
    }
    manifest = []
    for level in (0, 1, 6, 9):
        name = f"level{level}.zip"
        path = os.path.join(ZIP_DIR, name)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED if level else zipfile.ZIP_STORED,
                             compresslevel=level if level else None) as z:
            for n, data in payloads.items():
                z.writestr(n, data)
        with open(path, "rb") as f:
            raw = f.read()
        # Two corrupt copies that the reader must reject: one with a flipped
        # CRC in every central-directory entry, one with a flipped byte in the
        # first entry's compressed data.
        bad = bytearray(raw)
        i = 0
        while True:
            i = raw.find(b"PK\x01\x02", i)
            if i < 0:
                break
            bad[i + 16] ^= 0xFF
            i += 4
        with open(os.path.join(ZIP_DIR, f"bad_crc_{name}"), "wb") as f:
            f.write(bad)
        bad2 = bytearray(raw)
        lh = raw.find(b"PK\x03\x04")
        nlen = struct.unpack("<H", raw[lh + 26:lh + 28])[0]
        elen = struct.unpack("<H", raw[lh + 28:lh + 30])[0]
        data_at = lh + 30 + nlen + elen
        if data_at < len(bad2):
            bad2[data_at] ^= 0xFF
        with open(os.path.join(ZIP_DIR, f"bad_payload_{name}"), "wb") as f:
            f.write(bad2)
        manifest.append({"zip": name, "entries": len(payloads),
                         "sha256": hashlib.sha256(raw).hexdigest()})
        for n, data in payloads.items():
            with open(os.path.join(ZIP_DIR, n.replace("/", "_") + ".expected"), "wb") as f:
                f.write(data)
    with open(os.path.join(ZIP_DIR, "manifest.json"), "w") as f:
        json.dump({"generated_by": "tools/gen_zip_png_fixtures.py", "oracle": "python zipfile",
                   "archives": manifest, "names": list(payloads)}, f, indent=1)
    print(f"zip: {len(manifest)} archives + {len(manifest)} corrupt copies")


def png_chunk(ty, data):
    return struct.pack(">I", len(data)) + ty + data + struct.pack(">I", zlib.crc32(ty + data) & 0xFFFFFFFF)


def write_png(path, width, height, color_type, bit_depth, pixels, palette=None, trns=None,
              interlace=0, filters=None):
    """pixels: list of rows, each row a bytes object of raw sample data."""
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, interlace)
    raw = b""
    for y, row in enumerate(pixels):
        f = 0 if filters is None else filters[y % len(filters)]
        raw += bytes([f]) + row
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr)
    if palette is not None:
        out += png_chunk(b"PLTE", palette)
    if trns is not None:
        out += png_chunk(b"tRNS", trns)
    out += png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


def unfiltered_expected_rgba(width, height, pixels, color_type, bit_depth, palette, trns):
    """What the Goose decoder should produce, computed independently here."""
    out = bytearray()
    for row in pixels:
        if color_type == 6:
            out += row
        elif color_type == 2:
            for x in range(width):
                out += row[x * 3:x * 3 + 3] + b"\xff"
        elif color_type == 0:
            for x in range(width):
                v = row[x]
                out += bytes([v, v, v, 255])
        elif color_type == 3:
            for x in range(width):
                i = row[x]
                out += palette[i * 3:i * 3 + 3] + bytes([trns[i] if trns else 255])
        else:
            raise AssertionError(color_type)
    return bytes(out)


def make_png():
    os.makedirs(PNG_DIR, exist_ok=True)
    cases = []

    # RGBA with every filter type.
    w = h = 17
    rows = []
    for y in range(h):
        rows.append(bytes(((x * 11 + y * 7) & 0xFF) for x in range(w * 4)))
    for filt in (None, [0, 1, 2, 3, 4]):
        # Filters are applied by this writer only in the sense of tagging the
        # byte; the encoder below applies them properly.
        pass
    def encoded(rows, bpp, filters):
        """Apply PNG filters the way a real encoder does."""
        out = []
        prev = bytes(len(rows[0]))
        for y, row in enumerate(rows):
            f = filters[y % len(filters)]
            enc = bytearray()
            for i in range(len(row)):
                left = row[i - bpp] if i >= bpp else 0
                up = prev[i]
                ul = prev[i - bpp] if i >= bpp else 0
                if f == 0:
                    v = row[i]
                elif f == 1:
                    v = (row[i] - left) & 0xFF
                elif f == 2:
                    v = (row[i] - up) & 0xFF
                elif f == 3:
                    v = (row[i] - ((left + up) >> 1)) & 0xFF
                else:
                    p = left + up - ul
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
                    pr = left if pa <= pb and pa <= pc else (up if pb <= pc else ul)
                    v = (row[i] - pr) & 0xFF
                enc.append(v)
            out.append((bytes(enc), f))
            prev = row
        return out

    for filters in ([0], [1], [2], [3], [4], [0, 1, 2, 3, 4]):
        name = "rgba_f" + "".join(str(f) for f in filters)
        enc = encoded(rows, 4, filters)
        path = os.path.join(PNG_DIR, name + ".png")
        ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
        raw = b"".join(bytes([f]) + data for data, f in enc)
        out = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) +
               png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b""))
        with open(path, "wb") as f:
            f.write(out)
        with open(os.path.join(PNG_DIR, name + ".rgba"), "wb") as f:
            f.write(b"".join(rows))
        cases.append({"png": name, "w": w, "h": h, "color_type": 6})

    # RGB, gray, palette with tRNS.
    w, h = 16, 16
    rgb_rows = [b"".join(bytes(((x * 5) & 0xFF, (y * 9) & 0xFF, ((x + y) * 3) & 0xFF))
                         for x in range(w)) for y in range(h)]
    enc = encoded(rgb_rows, 3, [0, 4, 2])
    raw = b"".join(bytes([f]) + data for data, f in enc)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    with open(os.path.join(PNG_DIR, "rgb.png"), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) +
                png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b""))
    with open(os.path.join(PNG_DIR, "rgb.rgba"), "wb") as f:
        f.write(unfiltered_expected_rgba(w, h, rgb_rows, 2, 8, None, None))
    cases.append({"png": "rgb", "w": w, "h": h, "color_type": 2})

    gray_rows = [bytes((x * 16 + y) & 0xFF for x in range(w)) for y in range(h)]
    enc = encoded(gray_rows, 1, [0, 1])
    raw = b"".join(bytes([f]) + data for data, f in enc)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)
    with open(os.path.join(PNG_DIR, "gray.png"), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) +
                png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b""))
    with open(os.path.join(PNG_DIR, "gray.rgba"), "wb") as f:
        f.write(unfiltered_expected_rgba(w, h, gray_rows, 0, 8, None, None))
    cases.append({"png": "gray", "w": w, "h": h, "color_type": 0})

    palette = b"".join(bytes(((i * 16) & 0xFF, (i * 7) & 0xFF, (255 - i) & 0xFF)) for i in range(16))
    trns = bytes((i * 17) & 0xFF for i in range(16))
    pal_rows = [bytes((x + y) & 0x0F for x in range(w)) for y in range(h)]
    enc = encoded(pal_rows, 1, [0, 2])
    raw = b"".join(bytes([f]) + data for data, f in enc)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 3, 0, 0, 0)
    with open(os.path.join(PNG_DIR, "palette.png"), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"PLTE", palette) +
                png_chunk(b"tRNS", trns) + png_chunk(b"IDAT", zlib.compress(raw, 9)) +
                png_chunk(b"IEND", b""))
    with open(os.path.join(PNG_DIR, "palette.rgba"), "wb") as f:
        f.write(b"".join(bytes(palette[i * 3:i * 3 + 3]) + bytes([trns[i]]) for row in pal_rows for i in row))
    cases.append({"png": "palette", "w": w, "h": h, "color_type": 3})

    # 4-bit palette: Minecraft's older 16x16 textures are often 4-bit.
    pal4 = b"".join(bytes(((i * 16) & 0xFF, 0, (i * 5) & 0xFF)) for i in range(16))
    rows4 = []
    for y in range(16):
        idx = [(x + y) & 0x0F for x in range(16)]
        rows4.append(bytes(((idx[i] << 4) | idx[i + 1]) for i in range(0, 16, 2)))
    enc = encoded(rows4, 1, [0])
    raw = b"".join(bytes([f]) + data for data, f in enc)
    ihdr = struct.pack(">IIBBBBB", 16, 16, 4, 3, 0, 0, 0)
    with open(os.path.join(PNG_DIR, "palette4.png"), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"PLTE", pal4) +
                png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b""))
    with open(os.path.join(PNG_DIR, "palette4.rgba"), "wb") as f:
        for y in range(16):
            for x in range(16):
                i = (x + y) & 0x0F
                f.write(pal4[i * 3:i * 3 + 3] + b"\xff")
    cases.append({"png": "palette4", "w": 16, "h": 16, "color_type": 3})

    # Broken images: the gate must reject all of these.
    good = open(os.path.join(PNG_DIR, "rgb.png"), "rb").read()
    broken = {
        "bad_signature": b"XXXX" + good[4:],
        "bad_crc": good[:20] + bytes([good[20] ^ 0xFF]) + good[21:],
        "truncated": good[:40],
        "empty": b"",
    }
    for name, data in broken.items():
        with open(os.path.join(PNG_DIR, f"bad_{name}.png"), "wb") as f:
            f.write(data)

    with open(os.path.join(PNG_DIR, "manifest.json"), "w") as f:
        json.dump({"generated_by": "tools/gen_zip_png_fixtures.py", "cases": cases,
                   "broken": list(broken)}, f, indent=1)
    print(f"png: {len(cases)} images + {len(broken)} broken")


if __name__ == "__main__":
    make_zip()
    make_png()
