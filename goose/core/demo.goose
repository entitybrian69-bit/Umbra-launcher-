// Umbra core: the demo world.
//
// Nine 16x16 columns of stone, dirt, grass, water, trees and a plank path, generated
// from a seed with no file needed. It is not a world from a game save: gate 6b (a real
// world from the real server, compared block by block) is what a world from a save is.
//
// It lives in its own module so the app and the jar-driven renderer draw the same
// world: the app with the placeholder atlas, the renderer with the jar's own textures
// and models.

import std;
import core.region;
import core.mesh;
import core.models;
import core.modelstore;

// Cheap value noise, smoothed, so the terrain has hills without a noise module yet.
// Unchanged from the version the app has been shipping: the screenshot reference is
// a picture of this shape.
fn demo_height(x: i64, z: i64) -> i64 {
    let sx = ((x * 13 + z * 7) % 11) - 5;
    let sz = ((x * 5 + z * 17) % 13) - 6;
    return 64 + (sx * sx) / 6 - (sz * sz) / 9;
}

var demo: ChunkColumn[>..] = [];

// The one model the demo world draws from JSON instead of a whole cube. Shaped
// like the jar's `block/oak_slab` (a half-height box with per-face textures and a
// cullface on the bottom), so the model path the loader will use is the path the
// shipped world already takes.
let DEMO_SLAB_MODEL = "{\"textures\":{\"bottom\":\"minecraft:block/oak_planks\",\"top\":\"minecraft:block/oak_planks\",\"side\":\"minecraft:block/oak_planks\"},\"elements\":[{\"from\":[0,0,0],\"to\":[16,8,16],\"faces\":{\"down\":{\"texture\":\"#bottom\",\"cullface\":\"down\"},\"up\":{\"texture\":\"#top\"},\"north\":{\"texture\":\"#side\"},\"south\":{\"texture\":\"#side\"},\"west\":{\"texture\":\"#side\"},\"east\":{\"texture\":\"#side\"}}}]}";

fn demo_build(seed: i64) {
    // The demo world interns its own nine blocks -- but only when there is no jar's table
    // to keep. `bs_reset()` here wiped the 1288 blockstates the loaded jar had just
    // interned, and the hotbar, which is built from that table, came back nine blocks long
    // on a phone with the game's files: the device log said "9 block(s) in the list" beside
    // "1288 blockstates" from the jar, in the same run. The demo scene is a fallback for a
    // build with no jar, not a replacement for one.
    if bs_defs.len <= 1 { bs_reset(); }
    let stone = bs_intern("minecraft:stone", "");
    let dirt = bs_intern("minecraft:dirt", "");
    let grass = bs_intern("minecraft:grass_block", "snowy=false");
    let water = bs_intern("minecraft:water", "level=0");
    let log = bs_intern("minecraft:oak_log", "axis=y");
    let leaves = bs_intern("minecraft:oak_leaves", "distance=7");
    let plant = bs_intern("minecraft:short_grass", "half=bottom");
    let slab = bs_intern("minecraft:oak_slab", "type=bottom");
    // Parse the slab model and bind it: from here the mesher draws that block's
    // geometry from the model's own box and uv rects.
    mdl_reset();
    let slab_elements = mdl_parse(DEMO_SLAB_MODEL);
    // With the model store loaded (the jar-driven renderer) the slab is drawn from the
    // jar's own oak_slab model like any other block, so the single-model binding is
    // only for the placeholder build.
    if slab_elements > 0 && !mesh_store_active() { mesh_bind_model(slab); }
    demo = [];
    for cz in 3 {
        for cx in 3 {
            var c = column_new();
            for i in 24 {
                c.sections[i] = section_new();
                c.sections[i].present = true;
                c.sections[i].y = (i - 4) as i32;
            }
            c.section_lo = 0;
            c.section_hi = 23;
            c.x = cx as i32;
            c.z = cz as i32;
            c.present = true;
            for z in 16 {
                for x in 16 {
                    let wx = cx * 16 + x;
                    let wz = cz * 16 + z;
                    let h = demo_height(wx, wz) + (seed % 3);
                    for y in -64..h {
                        var id = stone;
                        if y > h - 4 { id = dirt; }
                        if y == h - 1 { id = grass; }
                        chunk_set_block(c, x as i32, y as i32, z as i32, id);
                    }
                    // A pond where the terrain dips.
                    if h < 62 {
                        for y in h..62 {
                            chunk_set_block(c, x as i32, y as i32, z as i32, water);
                        }
                    }
                    // Trees on a coarse grid, plants elsewhere.
                    if (wx % 9 == 4) && (wz % 9 == 4) && h >= 62 {
                        for y in 0..4 {
                            chunk_set_block(c, x as i32, (h + y) as i32, z as i32, log);
                        }
                        for dy in 2..6 {
                            for dz in -2..3 {
                                for dx in -2..3 {
                                    if (dx * dx + dz * dz) <= 4 && (dy < 5 || (dx * dx + dz * dz) <= 1) {
                                        let bx = x + dx;
                                        let bz = z + dz;
                                        if bx >= 0 && bx < 16 && bz >= 0 && bz < 16 {
                                            chunk_set_block(c, bx as i32, (h + dy) as i32, bz as i32, leaves);
                                        }
                                    }
                                }
                            }
                        }
                    } else if (wx * 31 + wz * 17) % 23 == 0 && h >= 62 {
                        chunk_set_block(c, x as i32, h as i32, z as i32, plant);
                    }
                    // A pond the body can swim in, where the terrain is already low
                    // enough that no digging is needed. The natural ponds only appear
                    // when the height function dips -- and with the seed the app ships
                    // (20261114) it does not dip anywhere, so the world had no water at
                    // all and "swimming" would have been untestable on the device. A
                    // basin carved into the lowest ground guarantees one: three blocks
                    // deep, at the size a body has room to swim in.
                    if h >= 61 && wx >= 30 && wx <= 45 && wz >= 6 && wz <= 17 {
                        for dy in -4..1 {
                            chunk_set_block(c, x as i32, (h + dy) as i32, z as i32, water);
                        }
                    }
                    // A short plank path along z where the ground is high enough to
                    // stand on: half-height blocks, drawn from the model.
                    if slab_elements > 0 && h >= 62 && (wx == 12 || wx == 13) &&
                       wz % 4 != 0 && wz >= 20 && wz <= 40 {
                        chunk_set_block(c, x as i32, h as i32, z as i32, slab);
                    }
                }
            }
            demo.push(c);
        }
    }
}


// --- looking at a block, and changing one --------------------------------
//
// The demo world is 9 columns of 16, so a world position is a column index plus an
// offset. Everything here refuses a position outside it rather than wrapping: an edit
// that silently lands in another column looks like a rendering bug.

// A world position to a column index and an offset inside it. The demo world was
// 0..47 and the old version refused anything negative -- which was right for a world
// that never had a negative coordinate, and wrong the moment a real save was loaded:
// a save's chunks are at -1,-1 as often as at 0,0, and the spawn of a real world is
// usually a negative chunk. The column is found by its own x/z, so a save with holes in
// it (which every save has) answers "no column" for the holes and the position for
// everything else.
fn demo_floor16(v: i32) -> i32 {
    let q = v / 16;
    if v < 0 && q * 16 != v { return q - 1; }
    return q;
}

fn demo_rem16(v: i32) -> i32 {
    let r = v - demo_floor16(v) * 16;
    return r;
}

fn demo_column_of(wx: i32, wz: i32) -> i64 {
    let cx = demo_floor16(wx);
    let cz = demo_floor16(wz);
    for i in demo.len {
        if demo[i].x == cx && demo[i].z == cz { return i; }
    }
    return -1;
}

// The floor height at a column: the first y, from the top of the world down, whose block
// can be stood on.
//
// The start is y 319, the top of the world, and that is the whole point of this function
// existing here rather than in the app. It used to start at 120 -- the demo scene's
// ceiling -- and a column whose surface was above 120 therefore answered with the first
// solid block *below* 120, which is a floor inside the terrain. The body spawned at 121
// with rock in every direction and could not move (run 44697024729, "no open cell within
// 6 blocks of 8,8; standing on the middle at floor 121.00"). A save is 384 blocks tall,
// so starting at the demo's height is not a shortcut, it is a wrong answer for the top
// 200 blocks of every world.
fn demo_floor_at(wx: i32, wz: i32) -> f32 {
    var y: i32 = 319;
    while y > -64 {
        let t = demo_top_at(wx, y, wz);
        if t > 0.0 { return (y as f32) + t; }
        y -= 1;
    }
    return 64.0;
}

// Is this cell something a body can stand on? -1 if not, the height of its box if so.
// Separated from the export in main because two callers ask it: the spawn scan here and
// the player's physics, and a rule stated twice is a rule that will disagree with itself.
fn demo_top_at(wx: i32, wy: i32, wz: i32) -> f32 {
    let id = demo_block_at(wx, wy, wz);
    if id == 0 { return -1.0; }
    let rc = render_class(id);
    // RC_AIR, not only id 0: a save's air is interned with its properties and so is a
    // different id with the same name (D-052). Asking `id == 0` and then falling through
    // to `return 1.0` gave every air block in a real world a solid top of 1.0 -- the body
    // stood on the top of the world at y 320 and the mesher culled nothing.
    if rc == RC_AIR { return -1.0; }
    if rc == RC_CROSS { return -1.0; }
    if rc == RC_TRANSLUCENT { return -1.0; }   // water is swimmable, not walked on
    return 1.0;
}

fn demo_block_at(wx: i32, wy: i32, wz: i32) -> u32 {
    let i = demo_column_of(wx, wz);
    if i < 0 { return 0; }
    return chunk_block(demo[i], demo_rem16(wx), wy, demo_rem16(wz));
}

fn demo_set_block(wx: i32, wy: i32, wz: i32, id: u32) -> bool {
    let i = demo_column_of(wx, wz);
    if i < 0 { return false; }
    chunk_set_block(demo[i], demo_rem16(wx), wy, demo_rem16(wz), id);
    return true;
}

fn demo_is_air(id: u32) -> bool {
    if id == 0 { return true; }
    let n = bs_name(id);
    if eq_bytes(n, "minecraft:air") { return true; }
    if eq_bytes(n, "minecraft:cave_air") { return true; }
    // `void_air` is the air beyond the world's edge, and the loader has always counted it
    // as air. Without this the renderer's non-air total included it and the loader's did
    // not, so the two numbers were never comparable even on a world that held still.
    if eq_bytes(n, "minecraft:void_air") { return true; }
    return false;
}

struct RayHit {
    hit: bool,
    x: i32, y: i32, z: i32,
    // Which side of the block was hit, in the mesher's face order: 0 -Y, 1 +Y, 2 -Z,
    // 3 +Z, 4 -X, 5 +X. A placement goes on that side.
    face: i64,
    id: u32,
}

// A ray walked cell by cell (the "amanatides and woo" traversal): step to whichever
// axis boundary is nearest and check the cell entered. A ray that starts inside a block
// hits it, which is what a body inside a wall should see.
fn demo_raycast(fx: f32, fy: f32, fz: f32, dx: f32, dy: f32, dz: f32, reach: f32) -> RayHit {
    var out = RayHit { hit: false, x: 0, y: 0, z: 0, face: -1, id: 0 };
    var len = dx * dx + dy * dy + dz * dz;
    if len <= 0.0 { return out; }
    let inv = 1.0 / len;
    let nx = dx * inv;
    let ny = dy * inv;
    let nz = dz * inv;
    var x = fx as i32;
    var y = fy as i32;
    var z = fz as i32;
    // Floor, not truncate: a negative coordinate truncates towards zero, which would
    // put the ray in the wrong cell.
    if fx < 0.0 && (fx as f32) != fx { x -= 1; }
    if fy < 0.0 && (fy as f32) != fy { y -= 1; }
    if fz < 0.0 && (fz as f32) != fz { z -= 1; }
    let stepx: i32 = if nx > 0.0 { 1 } else if nx < 0.0 { -1 } else { 0 };
    let stepy: i32 = if ny > 0.0 { 1 } else if ny < 0.0 { -1 } else { 0 };
    let stepz: i32 = if nz > 0.0 { 1 } else if nz < 0.0 { -1 } else { 0 };
    let inf: f32 = 1e30;
    var tmax_x = if stepx == 0 { inf } else if stepx > 0 { (1.0 - (fx - (x as f32))) / nx } else { ((x as f32) - fx) / nx };
    var tmax_y = if stepy == 0 { inf } else if stepy > 0 { (1.0 - (fy - (y as f32))) / ny } else { ((y as f32) - fy) / ny };
    var tmax_z = if stepz == 0 { inf } else if stepz > 0 { (1.0 - (fz - (z as f32))) / nz } else { ((z as f32) - fz) / nz };
    let tdx = if nx == 0.0 { inf } else { 1.0 / (if nx < 0.0 { 0.0 - nx } else { nx }) };
    let tdy = if ny == 0.0 { inf } else { 1.0 / (if ny < 0.0 { 0.0 - ny } else { ny }) };
    let tdz = if nz == 0.0 { inf } else { 1.0 / (if nz < 0.0 { 0.0 - nz } else { nz }) };
    var travelled: f32 = 0.0;
    var face: i64 = -1;
    for _guard in 512 {
        let id = demo_block_at(x, y, z);
        if !demo_is_air(id) {
            out.hit = true;
            out.x = x; out.y = y; out.z = z;
            out.face = face;
            out.id = id;
            return out;
        }
        if tmax_x <= tmax_y && tmax_x <= tmax_z {
            travelled = tmax_x;
            if travelled > reach { return out; }
            x += stepx;
            tmax_x += tdx;
            face = if stepx > 0 { 4 } else { 5 };
        } else if tmax_y <= tmax_z {
            travelled = tmax_y;
            if travelled > reach { return out; }
            y += stepy;
            tmax_y += tdy;
            face = if stepy > 0 { 0 } else { 1 };
        } else {
            travelled = tmax_z;
            if travelled > reach { return out; }
            z += stepz;
            tmax_z += tdz;
            face = if stepz > 0 { 2 } else { 3 };
        }
    }
    return out;
}

// The cell on the far side of `face` from a block: where a block would be placed.
fn demo_face_neighbour(h: RayHit, out: i32[3]&) {
    out[0] = h.x; out[1] = h.y; out[2] = h.z;
    if h.face == 0 { out[1] = h.y - 1; }
    if h.face == 1 { out[1] = h.y + 1; }
    if h.face == 2 { out[2] = h.z - 1; }
    if h.face == 3 { out[2] = h.z + 1; }
    if h.face == 4 { out[0] = h.x - 1; }
    if h.face == 5 { out[0] = h.x + 1; }
}
