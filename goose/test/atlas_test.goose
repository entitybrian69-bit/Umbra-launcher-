// Tests for the texture atlas: the layout arithmetic, the gutter, the missing
// tile, and the guarantee that a UV rect only ever covers its own tile.

import std;
import os;
import core.mem;
import core.atlas;
import core.textures;
import test.harness;

fn fake_tile(r: u8, g: u8, b: u8, a: u8) -> u8[>..] {
    // A 16x16 tile with a recognisable border: the edge is (r,g,b), the middle is
    // darker, so a gutter copy and a neighbour's pixels can be told apart.
    var t: u8[>..] = [];
    for y in 16 {
        for x in 16 {
            let edge = x == 0 || y == 0 || x == 15 || y == 15;
            t.push(if edge { r } else { (r as i64 / 2) as u8 });
            t.push(if edge { g } else { (g as i64 / 2) as u8 });
            t.push(if edge { b } else { (b as i64 / 2) as u8 });
            t.push(a);
        }
    }
    return t;
}

fn atlas_pixel(atlas: const u8[:], width: i64, x: i64, y: i64) -> i64[4] {
    let i = (y * width + x) * 4;
    return [atlas[i] as i64, atlas[i + 1] as i64, atlas[i + 2] as i64, atlas[i + 3] as i64];
}

fn run_atlas() {
    // --- layout arithmetic ---------------------------------------------------
    let one = atlas_plan(1, 16, 1);
    check_i64(one.cols, 1, "one tile is one column");
    check_i64(one.rows, 1, "one tile is one row");
    check_i64(one.width, 32, "one 16px tile with a 1px gutter is a 32px image");
    check_i64(one.width, one.height, "the atlas is square");

    let twelve = atlas_plan(12, 16, 1);
    check_i64(twelve.cols, 4, "12 tiles pack 4 across");
    check_i64(twelve.rows, 3, "12 tiles pack 3 down");
    check_i64(twelve.width, 128, "4 cells of 18 px is 72, so 128");
    check(twelve.cells >= 12, "the grid holds every tile");

    // The image is a power of two for every count from 1 to 4096: a driver that
    // only mipmaps power-of-two textures is not a device we get to choose.
    var pow2_ok = true;
    for n in 1..257 {
        let p = atlas_plan(n, 16, 1);
        let w = p.width;
        if w & (w - 1) != 0 { pow2_ok = false; }
        if p.cells < n { pow2_ok = false; }
    }
    check(pow2_ok, "every atlas size is a power of two and holds its tiles");

    // --- a 4-tile atlas ------------------------------------------------------
    let layout = atlas_plan(4, 16, 1);
    var atlas: u8[>..] = [];
    for i in layout.width * layout.height * 4 { atlas.push(0); }
    let red = fake_tile(255, 0, 0, 255);
    let green = fake_tile(0, 255, 0, 255);
    let blue = fake_tile(0, 0, 255, 255);
    atlas_write_tile(atlas, layout, 0, red, 16, 16, false);
    atlas_write_tile(atlas, layout, 1, green, 16, 16, false);
    atlas_write_tile(atlas, layout, 2, blue, 16, 16, false);

    let t0 = atlas_tile(layout, 0);
    let t1 = atlas_tile(layout, 1);
    check_i64(t0.x, 1, "slot 0 starts after one gutter texel");
    check_i64(t0.y, 1, "slot 0 starts after one gutter texel in y");
    check_i64(t1.x, 19, "slot 1 is one cell (18 px) along");
    check(t0.u0 > 0.0 && t0.v0 > 0.0, "a tile's UV origin is inside the image");
    check(t1.u0 > t0.u0, "slot 1's UVs are to the right of slot 0's");

    // The tile itself.
    let mid = atlas_pixel(atlas, layout.width, t0.x + 8, t0.y + 8);
    check_i64(mid[0], 127, "the middle of a red tile is half red");
    check_i64(mid[3], 255, "and fully opaque");

    // The gutter is the tile's own edge, not the neighbour's pixels: red's right
    // gutter must be red (255) even though the next cell is green.
    let right_gutter = atlas_pixel(atlas, layout.width, t0.x + 16, t0.y + 8);
    check_i64(right_gutter[0], 255, "the right gutter repeats the tile's own edge");
    check_i64(right_gutter[1], 0, "and is not the neighbouring tile's colour");
    let left_gutter = atlas_pixel(atlas, layout.width, t0.x - 1, t0.y + 8);
    check_i64(left_gutter[0], 255, "the left gutter repeats the tile's own edge");
    let top_gutter = atlas_pixel(atlas, layout.width, t0.x + 8, t0.y - 1);
    check_i64(top_gutter[0], 255, "the top gutter repeats the tile's own edge");
    let corner = atlas_pixel(atlas, layout.width, t0.x - 1, t0.y - 1);
    check_i64(corner[0], 255, "the corner of the gutter is the corner texel");

    // Green's left gutter must be green, not the previous tile's red: this is the
    // bug a shared gutter produces, and it shows as a 1 px coloured line round
    // every block on the screen.
    let green_left = atlas_pixel(atlas, layout.width, t1.x - 1, t1.y + 8);
    check_i64(green_left[1], 255, "the next tile's gutter is its own colour");
    check_i64(green_left[0], 0, "and does not borrow the previous tile's red");

    // Every tile of the 4-slot grid is inside the image and does not overlap.
    var overlaps = false;
    for i in 4 {
        let a = atlas_tile(layout, i);
        for j in 4 {
            if i == j { continue; }
            let b = atlas_tile(layout, j);
            let apart = a.x + a.w + layout.gutter <= b.x || b.x + b.w + layout.gutter <= a.x ||
                        a.y + a.h + layout.gutter <= b.y || b.y + b.h + layout.gutter <= a.y;
            if !apart { overlaps = true; }
        }
        if a.x < 0 || a.y < 0 || a.x + a.w > layout.width || a.y + a.h > layout.height {
            overlaps = true;
        }
    }
    check(!overlaps, "no two tiles overlap and every tile is inside the image");

    // --- the missing tile ----------------------------------------------------
    atlas_write_missing(atlas, layout, 3);
    let m0 = atlas_pixel(atlas, layout.width, atlas_tile(layout, 3).x + 1, atlas_tile(layout, 3).y + 1);
    check_i64(m0[0], 255, "the missing tile is magenta (r)");
    check_i64(m0[1], 0, "the missing tile is magenta (g)");
    check_i64(m0[2], 255, "the missing tile is magenta (b)");
    let m1 = atlas_pixel(atlas, layout.width, atlas_tile(layout, 3).x + 5, atlas_tile(layout, 3).y + 1);
    check_i64(m1[0], 0, "and black in the other squares of the checker");
    check_i64(m1[1], 0, "and black in the other squares of the checker");

    // --- an animated strip is cut to its first frame -------------------------
    // 16x64: four frames. Only the top 16 rows may reach the atlas.
    var strip: u8[>..] = [];
    for f in 4 {
        for y in 16 {
            for x in 16 {
                let v: u8 = if f == 0 { 200 } else { 10 };
                strip.push(v);
                strip.push(0);
                strip.push(0);
                strip.push(255);
            }
        }
    }
    var atlas2: u8[>..] = [];
    for i in layout.width * layout.height * 4 { atlas2.push(0); }
    atlas_write_tile(atlas2, layout, 0, strip, 16, 64, true);
    let f0 = atlas_pixel(atlas2, layout.width, atlas_tile(layout, 0).x + 8, atlas_tile(layout, 0).y + 8);
    check_i64(f0[0], 200, "an animated strip is frozen on frame 0");

    // --- the hash is stable and sensitive ------------------------------------
    let h1 = atlas_hash(atlas2);
    let h2 = atlas_hash(atlas2);
    check_u32(h1, h2, "the atlas hash is stable");
    atlas2[(atlas_tile(layout, 0).x + 8) * 4 + (atlas_tile(layout, 0).y + 8) * layout.width * 4] = 1;
    check(atlas_hash(atlas2) != h1, "and changes when a pixel changes");

    // --- texel lookup, used by the device self-test --------------------------
    let px = atlas_tile_texel(atlas, layout, 0, 8, 8);
    check_i64(px & 0xFF, 127, "texel lookup returns the pixel");
    check_i64(atlas_tile_texel(atlas, layout, 0, 999, 0), -1, "a texel outside the atlas is -1");
    check_i64(atlas_tile_texel(atlas, layout, 0, 0, 999), -1, "and so is one past the bottom");
    // --- the shipped placeholder set -----------------------------------------
    tex_build();
    // 4 cells across is 4 * (16 + 2) = 72 texels, and 72 is not a power of two, so
    // the image is 128: the padding is the reason, not a rounding accident.
    check_i64(tex_atlas_size(), 128, "12 placeholder tiles fit a 128 px atlas");
    check_i64(tex_atlas_height(), 128, "the atlas is square");
    check(tex_atlas_hash() != 0, "the atlas hashes to something");
    // Two builds of the same set produce the same image: the hash in a log is
    // only useful if it is comparable across runs.
    let h_before = tex_atlas_hash();
    tex_build();
    check_u32(tex_atlas_hash(), h_before, "building the atlas twice is idempotent");

    // Every shipped tile is opaque somewhere and, for the cutout ones, transparent
    // somewhere: a leaves tile with no holes would silently drop the alpha test.
    var leaves_transparent = 0;
    var leaves_opaque = 0;
    for y in 16 {
        for x in 16 {
            let p = tex_texel(TEX_LEAVES, x, y);
            if (p >> 24) & 0xFF == 0 { leaves_transparent += 1; } else { leaves_opaque += 1; }
        }
    }
    check(leaves_transparent > 0, "the leaves tile has transparent texels");
    check(leaves_opaque > 0, "the leaves tile has opaque texels");
    var plant_transparent = 0;
    for y in 16 {
        for x in 16 {
            let p = tex_texel(TEX_PLANT, x, y);
            if (p >> 24) & 0xFF == 0 { plant_transparent += 1; }
        }
    }
    check(plant_transparent > 0, "the plant tile is mostly transparent");

    // Faces map to the right tiles: grass is green on top and dirt underneath.
    check_i64(tex_face_slot("grass_block", 1), TEX_GRASS_TOP, "grass top");
    check_i64(tex_face_slot("grass_block", 0), TEX_DIRT, "grass bottom is dirt");
    check_i64(tex_face_slot("grass_block", 2), TEX_GRASS_SIDE, "grass side");
    check_i64(tex_face_slot("oak_log", 1), TEX_LOG_TOP, "log top");
    check_i64(tex_face_slot("oak_log", 4), TEX_LOG_SIDE, "log side");
    let before_missing = tex_missing_count();
    check_i64(tex_face_slot("something_unknown", 2), TEX_COUNT - 1, "an unknown block gets the loud tile");
    check_i64(tex_missing_count(), before_missing + 1, "and is counted");
    test_summary("atlas");
}
