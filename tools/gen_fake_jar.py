#!/usr/bin/env python3
"""Build a synthetic jar that has the shape of the real one, for testing the
jar checker itself.

This is not game data and contains nothing from the game: it is generated here,
so the checker can be exercised on every run (and on a machine with no network)
without pretending the real jar was examined. Its numbers are far below the
real jar's, and `tools/fetch_jar.sh` is the only path that ever produces real
data.

usage: tools/gen_fake_jar.py <out.jar> [--broken]
  --broken  omit textures, parents and a box corner that the checker must catch
"""
import io
import json
import struct
import sys
import zipfile
import zlib

BLOCKS = 520
MODELS = 1100
TEXTURES = 510


def png_rgba(w: int, h: int, rgba: tuple) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(rgba) * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def model_text(name: str, texture: str, parent="block/block") -> dict:
    faces = {f: {"texture": "#all", "uv": [0, 0, 16, 16]} for f in
             ("down", "up", "north", "south", "west", "east")}
    return {
        "parent": parent,
        "textures": {"particle": texture, "all": texture},
        "elements": [
            {"from": [0, 0, 0], "to": [16, 16, 16], "faces": faces}
        ],
    }


def build(path: str, broken: bool) -> None:
    z = zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED)
    # The real jar has these; the checker ignores them, so it should here too.
    z.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
    z.writestr("assets/minecraft/lang/en_us.json", '{"block.minecraft.stone":"Stone"}')

    tex_names = [f"block/fake_{i}" for i in range(TEXTURES)]
    for i, name in enumerate(tex_names):
        # A missing last texture is the break in --broken mode.
        if broken and i == TEXTURES - 1:
            continue
        z.writestr(f"assets/minecraft/textures/{name}.png", png_rgba(16, 16, (10, 20, 30, 255)))

    # A parent that defines a texture its children only name as a variable, so
    # the "#var inherited from the parent" path is exercised.
    z.writestr("assets/minecraft/models/block/fake_varparent.json",
               json.dumps({"parent": "block/block",
                           "textures": {"all": "block/fake_3", "particle": "#all"}}))

    # A parent model every other model inherits from.
    z.writestr("assets/minecraft/models/block/block.json",
               json.dumps({"textures": {"particle": "block/fake_0"}}))

    model_names = []
    for i in range(MODELS):
        name = f"block/fake_{i}"
        model_names.append(name)
        if broken and i == MODELS - 1:
            tex = "block/does_not_exist"
        else:
            tex = tex_names[i % TEXTURES]
        body = model_text(name, tex, parent="block/block")
        if broken and i == 5:
            # A variable that resolves neither here nor in the parent.
            body["textures"] = {"particle": "#missing_var", "all": tex}
        if i % 10 == 3:
            # particle comes from the parent; `all` is still defined here.
            body = model_text(name, tex, parent="block/fake_varparent")
            body["textures"] = {"particle": "#all", "all": tex}
        if broken and i == MODELS - 2:
            body["elements"][0]["from"] = [20, 0, 0]   # from > to
        z.writestr(f"assets/minecraft/models/{name}.json", json.dumps(body))

    # One all-cube model with no parent of its own, so the "no parent" branch
    # gets exercised too.
    z.writestr("assets/minecraft/models/block/fake_root.json",
               json.dumps({"textures": {"all": "block/fake_1"},
                           "elements": model_text("x", "y")["elements"]}))

    for i in range(BLOCKS):
        ref = model_names[i % MODELS]
        if broken and i == BLOCKS - 1:
            ref = "block/nowhere"
        if i % 7 == 0:
            # multipart with a weighted apply array
            doc = {"multipart": [
                {"when": {"north": "true"},
                 "apply": [{"model": ref}, {"model": ref, "weight": 3}]},
                {"apply": {"model": ref}},
            ]}
        else:
            doc = {"variants": {f"facing=north,level={j}": {"model": ref} for j in range(4)}}
        z.writestr(f"assets/minecraft/blockstates/fake_{i}.json", json.dumps(doc))
    z.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    build(sys.argv[1], "--broken" in sys.argv)
    print("wrote", sys.argv[1])
