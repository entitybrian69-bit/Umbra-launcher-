#!/usr/bin/env python3
"""Generate DEFLATE/zlib fixtures for the Goose inflate test.

The oracle here is zlib itself (Python's zlib module), so the Goose decoder is
checked against an independent implementation on real compressor output rather
than against data the Goose decoder produced.
"""
import os, random, zlib, hashlib, json, sys

OUT = os.path.join(os.path.dirname(__file__), "..", "goose", "test", "fixtures", "inflate")
OUT = os.path.abspath(OUT)


def cases():
    rnd = random.Random(20261114)
    yield ("empty", b"")
    yield ("one", b"A")
    yield ("text", (b"The quick brown fox jumps over the lazy dog. " * 40))
    yield ("bytes", bytes(range(256)) * 8)
    yield ("random", bytes(rnd.randrange(256) for _ in range(2500)))
    yield ("runs", b"\x00" * 9000)
    yield ("mixed", bytes(rnd.randrange(4) for _ in range(7000)))
    # A tiny PNG-like payload: filter bytes interleaved with pixel rows.
    rows = b"".join(bytes([0]) + bytes((x * 7 + y) & 0xFF for x in range(64)) for y in range(64))
    yield ("pnglike", rows)


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = []
    for name, data in cases():
        for level in (0, 1, 6, 9):
            for strategy in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FIXED):
                co = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
                raw = co.compress(data) + co.flush()
                tag = f"{name}_l{level}_s{strategy}"
                with open(os.path.join(OUT, tag + ".deflate"), "wb") as f:
                    f.write(raw)
                with open(os.path.join(OUT, tag + ".plain"), "wb") as f:
                    f.write(data)
                manifest.append({"case": tag, "n": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        # zlib-wrapped stream (Anvil region chunks and PNG both use this).
        wrap = zlib.compress(data, 6)
        with open(os.path.join(OUT, name + ".zlib"), "wb") as f:
            f.write(wrap)
        with open(os.path.join(OUT, name + ".zplain"), "wb") as f:
            f.write(data)
        manifest.append({"case": name, "n": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    # Deliberately broken inputs: the gate must reject these.
    good = zlib.compress(b"hello world" * 100, 6)
    broken = {
        "corrupt_adler": good[:-1] + bytes([good[-1] ^ 0xFF]),
        "truncated": good[: len(good) // 2],
        "reserved_block": b"\x07\x00",
        "garbage": bytes([0xFF, 0xFF, 0xFF, 0xFF]),
    }
    for name, data in broken.items():
        with open(os.path.join(OUT, f"bad_{name}.zlib"), "wb") as f:
            f.write(data)
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump({"generated_by": "tools/gen_inflate_fixtures.py", "oracle": "zlib",
                   "cases": manifest}, f, indent=1)
    print(f"wrote {len(manifest)} good cases + {len(broken)} broken cases to {OUT}")


if __name__ == "__main__":
    main()
