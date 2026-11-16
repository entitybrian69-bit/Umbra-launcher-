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


def png_gradient(w: int, h: int) -> bytes:
    """A 256x256 image whose pixel (x, y) is (x, y, 128): the colormap sample point
    is then a number the test can predict, instead of a colour nobody can check."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(v for x in range(w) for v in (x, y, 128, 255))
                   for y in range(h))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def model_text(name: str, texture: str, parent="block/block") -> dict:
    # cullface on all six, like the real block/cube_all.json: two touching blocks must
    # hide the faces between them, or a world is six faces per block of rock.
    faces = {f: {"texture": "#all", "uv": [0, 0, 16, 16], "cullface": f} for f in
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
    # One animated-looking strip texture (16x64, four frames), which is legal.
    z.writestr("assets/minecraft/textures/block/fake_animated.png", png_rgba(16, 64, (60, 70, 80, 255)))

    # The root every model inherits from. It defines no elements, like the real
    # block/block.json, and is itself unused by any blockstate.
    z.writestr("assets/minecraft/models/block/block.json",
               json.dumps({"textures": {"particle": "block/fake_0"}}))

    # A template exactly like the real block/cube_all.json: its textures are
    # slots a child fills in, so on its own it resolves nowhere and that is fine
    # as long as no blockstate uses it directly.
    z.writestr("assets/minecraft/models/block/fake_template.json",
               json.dumps({"textures": {"all": "#all", "particle": "#all"},
                           "elements": model_text("t", "x")["elements"]}))

    # A parent that defines a texture its children only name as a variable.
    z.writestr("assets/minecraft/models/block/fake_varparent.json",
               json.dumps({"parent": "block/block",
                           "textures": {"all": "block/fake_3", "particle": "#all"}}))

    # An unused model with a texture that does not exist — the real block/air.json
    # is exactly this, and it is not a fault because nothing draws it.
    z.writestr("assets/minecraft/models/block/fake_air.json",
               json.dumps({"textures": {"particle": "block/not_here"}}))

    # A sprite object instead of a bare name, like the real stained glass models
    # since 26.3: {"sprite": "...", "force_translucent": true}.
    spr = model_text("sprite", "block/fake_2")
    spr["textures"] = {"all": {"sprite": "minecraft:block/fake_2", "force_translucent": True}}
    # ...and a face that names its key without the '#' (26.3's heavy_core does).
    spr["elements"][0]["faces"]["up"]["texture"] = "all"
    z.writestr("assets/minecraft/models/block/fake_sprite.json", json.dumps(spr))

    # An inverted box, like the real block/cube_all_inner_faces.json: legal.
    inner = model_text("inner", "block/fake_4")
    inner["elements"][0]["from"] = [16, 0, 16]
    inner["elements"][0]["to"] = [0, 16, 0]
    z.writestr("assets/minecraft/models/block/fake_inner_faces.json", json.dumps(inner))

    model_names = []
    for i in range(MODELS):
        name = f"block/fake_{i}"
        model_names.append(name)
        tex = tex_names[i % TEXTURES]
        body = model_text(name, tex, parent="block/block")
        if i % 10 == 3:
            # Inherits `all` from the parent; defines only the slot it names.
            body = model_text(name, tex, parent="block/fake_varparent")
            body["textures"] = {"particle": "#all"}
        if broken and i == 5:
            # A face that names a slot nothing in the chain defines.
            body["elements"][0]["faces"]["up"]["texture"] = "#missing_key"
        if broken and i == 7:
            body["parent"] = "block/no_such_parent"
        if broken and i == MODELS - 1:
            tex_body = model_text(name, "block/does_not_exist", parent="block/block")
            z.writestr(f"assets/minecraft/models/{name}.json", json.dumps(tex_body))
            continue
        z.writestr(f"assets/minecraft/models/{name}.json", json.dumps(body))

    # A model with no parent at all.
    z.writestr("assets/minecraft/models/block/fake_root.json",
               json.dumps({"textures": {"all": "block/fake_1"},
                           "elements": model_text("x", "y")["elements"]}))

    # The three colormaps the client tints grass, leaves and water with. Invented like
    # the rest of this jar, and shaped so a sample can be checked by arithmetic.
    for cmap in ("grass", "foliage", "water"):
        z.writestr(f"assets/minecraft/textures/colormap/{cmap}.png", png_gradient(256, 256))

    # The eight blocks the demo world is built from, under their real names, so the
    # jar-driven renderer can draw that world from a jar that exists on a machine with
    # no network. The colours are invented (one flat colour per block) and stand in for
    # the real art: what this proves is the path - blockstate to model to atlas to
    # picture - and the real jar is what proves the art.
    demo_blocks = {
        "stone": (128, 128, 128, 255),
        "dirt": (134, 96, 67, 255),
        "grass_block": (95, 159, 53, 255),
        "oak_log": (102, 81, 50, 255),
        "oak_leaves": (52, 122, 40, 255),
        "water": (63, 118, 228, 170),
        "short_grass": (110, 168, 60, 255),
        "oak_slab": (162, 130, 78, 255),
    }
    sides = ("down", "up", "north", "south", "west", "east")
    for name, colour in demo_blocks.items():
        z.writestr(f"assets/minecraft/textures/block/{name}.png", png_rgba(16, 16, colour))
        if name == "oak_slab":
            body = {"parent": "block/block",
                    "textures": {"all": f"block/{name}", "particle": f"block/{name}"},
                    "elements": [{"from": [0, 0, 0], "to": [16, 8, 16],
                                  "faces": {f: {"texture": "#all", "cullface": f} for f in sides}}]}
        else:
            body = model_text(name, f"block/{name}")
        z.writestr(f"assets/minecraft/models/block/{name}.json", json.dumps(body))
        z.writestr(f"assets/minecraft/blockstates/{name}.json",
                   json.dumps({"variants": {"": {"model": f"block/{name}"}}}))

    for i in range(BLOCKS):
        ref = model_names[i % MODELS]
        if i == 5:
            ref = "block/fake_varparent_child_unused" if False else ref
        if broken and i == BLOCKS - 1:
            ref = "block/nowhere"
        if i % 7 == 0:
            doc = {"multipart": [
                {"when": {"north": "true"},
                 "apply": [{"model": ref}, {"model": ref, "weight": 3}]},
                {"apply": {"model": ref}},
            ]}
        elif i % 11 == 0:
            doc = {"variants": {"": {"model": "block/fake_inner_faces"}}}
        elif i % 13 == 0:
            doc = {"variants": {"": {"model": "block/fake_root"}}}
        elif i % 17 == 0:
            doc = {"variants": {"": {"model": "block/fake_sprite"}}}
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
