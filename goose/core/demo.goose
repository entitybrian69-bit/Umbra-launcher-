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
    bs_reset();
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

