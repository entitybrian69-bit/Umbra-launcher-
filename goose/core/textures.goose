// Umbra core: the placeholder texture set, and the atlas that holds it.
//
// Why placeholders and not the jar's own textures: Umbra ships no Mojang assets,
// in the repository or in the APK (see DECISIONS.md D-039). The real pipeline -
// PNG decode, atlas packing, model UVs, the GPU upload - is the same code the jar
// drives, and CI proves that half against the real jar's 3964 textures at test
// time. What it draws here is art this project owns: sixteen tiles that look
// enough like the materials they stand for that a screenshot reads correctly.
//
// Every tile is procedural: a colour, a little ordered noise, and a pattern that
// makes a face recognisable. Nothing is copied, and nothing needs a PNG decoder
// to produce, which also means the demo world cannot fail to load a texture.

import std;
import core.mem;
import core.atlas;

const TEX_TILE: i64 = 16;

// One entry per tile the demo world uses, in a fixed order. The slot is the index
// into this table, and into the atlas grid.
let TEX_STONE = 0;
let TEX_DIRT = 1;
let TEX_GRASS_TOP = 2;
let TEX_GRASS_SIDE = 3;
let TEX_SAND = 4;
let TEX_LOG_SIDE = 5;
let TEX_LOG_TOP = 6;
let TEX_PLANKS = 7;
let TEX_LEAVES = 8;
let TEX_WATER = 9;
let TEX_GLASS = 10;
let TEX_PLANT = 11;
let TEX_COUNT = 12;

var tex_atlas: u8[>..] = [];
var tex_layout = atlas_plan(TEX_COUNT, TEX_TILE, 1);
var tex_built = false;
var tex_missing_hits: i64 = 0;

// --- pixel helpers -------------------------------------------------------

fn tex_index(x: i64, y: i64) -> i64 { return (y * TEX_TILE + x) * 4; }

fn tex_put(t: u8[>..]&, x: i64, y: i64, r: i64, g: i64, b: i64, a: i64) {
    let i = tex_index(x, y);
    t[i] = clamp_u8(r);
    t[i + 1] = clamp_u8(g);
    t[i + 2] = clamp_u8(b);
    t[i + 3] = clamp_u8(a);
}

fn clamp_u8(v: i64) -> u8 {
    if v < 0 { return 0; }
    if v > 255 { return 255; }
    return v as u8;
}

// Deterministic noise: a hash of the position and a salt, so two runs draw the
// same tile and the atlas hash in the log is comparable across builds.
fn tex_noise(x: i64, y: i64, salt: i64) -> i64 {
    var h = (x * 374761393 + y * 668265263 + salt * 1442695040888963407) & 0xFFFFFFFF;
    h = (h ^ (h >> 13)) * 1274126177;
    h = h & 0xFFFFFFFF;
    return (h >> 8) & 0xFF;
}

fn tex_new() -> u8[>..] {
    var t: u8[>..] = [];
    for i in TEX_TILE * TEX_TILE * 4 { t.push(0); }
    return t;
}

// --- the tiles -----------------------------------------------------------

// Grey stone with a few darker speckles.
fn tex_stone() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 1);
            let v = 118 + (n % 24) - 12;
            var r = v;
            var g = v;
            var b = v + 2;
            if n > 244 { r = r - 26; g = g - 26; b = b - 24; }
            tex_put(t, x, y, r, g, b, 255);
        }
    }
    return t;
}

fn tex_dirt() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 2);
            let v = 104 + (n % 30) - 15;
            var r = v + 30;
            var g = (v * 70) / 100 + 16;
            var b = (v * 45) / 100 + 8;
            if n > 236 { r = r + 18; g = g + 12; b = b + 6; }
            tex_put(t, x, y, r, g, b, 255);
        }
    }
    return t;
}

fn tex_grass_top() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 3);
            let v = 92 + (n % 26);
            tex_put(t, x, y, v / 2 + 12, v + 36, v / 3 + 10, 255);
        }
    }
    return t;
}

// Dirt with a ragged green band along the top edge, three texels deep, so the
// side of a grass block reads as grass on top of dirt.
fn tex_grass_side() -> u8[>..] {
    var t = tex_dirt();
    for x in TEX_TILE {
        let depth = 2 + (tex_noise(x, 0, 4) % 3);
        for y in depth {
            let n = tex_noise(x, y, 5);
            let v = 88 + (n % 28);
            tex_put(t, x, y, v / 2 + 10, v + 30, v / 3 + 8, 255);
        }
    }
    return t;
}

fn tex_sand() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 6);
            let v = 188 + (n % 20);
            tex_put(t, x, y, v, v - 14, v - 60, 255);
        }
    }
    return t;
}

// Vertical bark: darker grooves every few columns.
fn tex_log_side() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 7);
            let groove = x % 4 == 0;
            var v = 78 + (n % 18);
            if groove { v = v - 20; }
            tex_put(t, x, y, v + 26, v + 6, v - 12, 255);
        }
    }
    return t;
}

// Rings: a ring every three texels out from the centre.
fn tex_log_top() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let dx = x - 8;
            let dy = y - 8;
            let d = (abs(dx) + abs(dy)) / 2;
            let n = tex_noise(x, y, 8);
            var v = 150 + (n % 14);
            if d % 3 == 0 { v = v - 26; }
            tex_put(t, x, y, v + 8, v - 22, v - 70, 255);
        }
    }
    return t;
}

// Four planks with a dark seam between each.
fn tex_planks() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 9);
            let seam = y % 4 == 0 || (x == (y / 4) * 5 % 16);
            var v = 132 + (n % 16);
            if seam { v = v - 34; }
            tex_put(t, x, y, v + 22, v - 30, v - 78, 255);
        }
    }
    return t;
}

// Leaves: a green base with transparent holes, which is what makes the cutout
// path testable - the shader has to discard these texels, not blend them.
fn tex_leaves() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 10);
            let hole = n > 200;
            let v = 70 + (n % 40);
            if hole {
                tex_put(t, x, y, 0, 0, 0, 0);
            } else {
                tex_put(t, x, y, v / 2 + 10, v + 40, v / 3 + 12, 255);
            }
        }
    }
    return t;
}

fn tex_water() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let n = tex_noise(x, y, 11);
            let wave = ((x + y * 2 + (n % 3)) % 8) < 2;
            let v = 60 + (n % 16);
            if wave { tex_put(t, x, y, 40, 96 + v, 190, 190); }
            else { tex_put(t, x, y, 28, 74 + v, 168, 180); }
        }
    }
    return t;
}

// Glass: a mostly transparent pane with a bright frame.
fn tex_glass() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            let edge = x == 0 || y == 0 || x == 15 || y == 15;
            if edge { tex_put(t, x, y, 210, 232, 240, 210); }
            else if x == 1 && y < 6 { tex_put(t, x, y, 240, 250, 255, 90); }
            else { tex_put(t, x, y, 200, 225, 235, 30); }
        }
    }
    return t;
}

// Grass tufts on a transparent background: the cross-plant tile.
fn tex_plant() -> u8[>..] {
    var t = tex_new();
    for y in TEX_TILE {
        for x in TEX_TILE {
            tex_put(t, x, y, 0, 0, 0, 0);
        }
    }
    for blade in 5 {
        let bx = 2 + blade * 3;
        let h = 8 + (tex_noise(blade, 0, 12) % 7);
        for k in h {
            let y = TEX_TILE - 1 - k;
            let bend = (k * (blade - 2)) / 12;
            let n = tex_noise(bx + k, y, 13);
            tex_put(t, bx + bend, y, 60 + n % 30, 130 + n % 40, 50 + n % 20, 255);
        }
    }
    return t;
}

// --- the atlas -----------------------------------------------------------

fn tex_tile_pixels(slot: i64) -> u8[>..] {
    if slot == TEX_STONE { return tex_stone(); }
    if slot == TEX_DIRT { return tex_dirt(); }
    if slot == TEX_GRASS_TOP { return tex_grass_top(); }
    if slot == TEX_GRASS_SIDE { return tex_grass_side(); }
    if slot == TEX_SAND { return tex_sand(); }
    if slot == TEX_LOG_SIDE { return tex_log_side(); }
    if slot == TEX_LOG_TOP { return tex_log_top(); }
    if slot == TEX_PLANKS { return tex_planks(); }
    if slot == TEX_LEAVES { return tex_leaves(); }
    if slot == TEX_WATER { return tex_water(); }
    if slot == TEX_GLASS { return tex_glass(); }
    if slot == TEX_PLANT { return tex_plant(); }
    return tex_stone();
}

// Builds the atlas once. Every later call is free: the pixel buffer is owned by
// this module and the C side uploads it to a GL texture.
fn tex_build() {
    if tex_built { return; }
    tex_layout = atlas_plan(TEX_COUNT, TEX_TILE, 1);
    tex_atlas = [];
    for i in tex_layout.width * tex_layout.height * 4 { tex_atlas.push(0); }
    // The last slot is the loud one, and nothing names it: if a block ever maps to
    // it, the magenta tile is on screen and the count says so.
    for slot in TEX_COUNT {
        let px = tex_tile_pixels(slot);
        atlas_write_tile(tex_atlas, tex_layout, slot, px, TEX_TILE, TEX_TILE, false);
    }
    tex_built = true;
}

fn tex_atlas_size() -> i64 { return tex_layout.width; }
fn tex_atlas_height() -> i64 { return tex_layout.height; }

// The UV rect of a slot, as [u0, v0, u1, v1].
fn tex_uv(slot: i64) -> f32[4] {
    let t = atlas_tile(tex_layout, slot);
    return [t.u0, t.v0, t.u1, t.v1];
}

// The atlas pixel of a slot, for the device self-test.
fn tex_texel(slot: i64, x: i64, y: i64) -> i64 {
    return atlas_tile_texel(tex_atlas, tex_layout, slot, x, y);
}

fn tex_atlas_hash() -> u32 { return atlas_hash(tex_atlas); }

// A name a block model would use, mapped to this set. Anything unknown is the
// loud tile and is counted, so a demo world that names a texture this build does
// not have is a visible defect rather than a quiet grey block.
fn tex_slot_for(name: const u8[:]) -> i64 {
    if eq_bytes(name, "stone") { return TEX_STONE; }
    if eq_bytes(name, "dirt") { return TEX_DIRT; }
    if eq_bytes(name, "grass_block_top") { return TEX_GRASS_TOP; }
    if eq_bytes(name, "grass_block_side") { return TEX_GRASS_SIDE; }
    if eq_bytes(name, "sand") { return TEX_SAND; }
    if eq_bytes(name, "oak_log") { return TEX_LOG_SIDE; }
    if eq_bytes(name, "oak_log_top") { return TEX_LOG_TOP; }
    if eq_bytes(name, "oak_planks") { return TEX_PLANKS; }
    if eq_bytes(name, "oak_leaves") { return TEX_LEAVES; }
    if eq_bytes(name, "water_still") { return TEX_WATER; }
    if eq_bytes(name, "glass") { return TEX_GLASS; }
    if eq_bytes(name, "short_grass") { return TEX_PLANT; }
    tex_missing_hits += 1;
    return TEX_COUNT - 1;
}

// Which tile a block face uses, in the three-way split block models have: top,
// bottom, side. The demo world only needs this table; the jar's models replace it
// with their own `textures` map (see core/models.goose).
fn tex_face_slot(path: const u8[:], face: i64) -> i64 {
    let top = face == 1;
    let bottom = face == 0;
    if eq_bytes(path, "grass_block") {
        if top { return TEX_GRASS_TOP; }
        if bottom { return TEX_DIRT; }
        return TEX_GRASS_SIDE;
    }
    if eq_bytes(path, "oak_log") || ends_with(path, "_log") {
        if top || bottom { return TEX_LOG_TOP; }
        return TEX_LOG_SIDE;
    }
    if eq_bytes(path, "oak_leaves") || ends_with(path, "_leaves") { return TEX_LEAVES; }
    if eq_bytes(path, "water") || ends_with(path, "_water") { return TEX_WATER; }
    if eq_bytes(path, "glass") { return TEX_GLASS; }
    if eq_bytes(path, "short_grass") || eq_bytes(path, "fern") { return TEX_PLANT; }
    if eq_bytes(path, "sand") { return TEX_SAND; }
    if eq_bytes(path, "oak_planks") || ends_with(path, "_planks") { return TEX_PLANKS; }
    if eq_bytes(path, "dirt") || ends_with(path, "_dirt") { return TEX_DIRT; }
    if eq_bytes(path, "stone") { return TEX_STONE; }
    tex_missing_hits += 1;
    return TEX_COUNT - 1;
}

fn tex_missing_count() -> i64 { return tex_missing_hits; }
