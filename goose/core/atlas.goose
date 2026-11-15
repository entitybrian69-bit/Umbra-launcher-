// Umbra core: the texture atlas.
//
// Every block texture the client draws is a 16x16 tile from the jar (animated
// textures are 16x(16*n) strips, and are frozen on frame 0). The GPU draws them
// all from one texture, so they have to be packed into one image with these
// properties, each of which was a bug in some other project first:
//
//   * a real gutter. A tile's neighbours' pixels bleed into it under bilinear
//     filtering and mipmapping, so each tile is surrounded by a copy of its own
//     edge. The UV rect the mesher emits points at the tile inside the gutter, so
//     a fraction of a texel can never land on another tile.
//   * a power-of-two size, because GLES 2-era drivers and some 3.0 drivers only
//     generate mipmaps for power-of-two textures, and a non-mipmapped atlas
//     shimmers on a phone at any distance.
//   * a loud magenta tile for a texture that is missing, so a wrong path in a
//     model shows up as magenta in a screenshot instead of as a black or white
//     square that looks like a lighting bug. The count is reported so a test can
//     fail on it.
//
// The layout is a simple grid: `cols` tiles across, `rows` down, each cell
// `tile + 2*gutter` texels. At 16 px tiles and a 1 px gutter the smallest atlas
// that holds the 12 placeholder tiles this client ships is 64x64; the jar's full
// block set needs 1024x1024 at that size, which is why the size is computed from
// the count and not fixed.

import std;
import core.mem;

// A tile's place in the atlas, in texels. `u0..v1` is the rect the mesher writes
// into a vertex, in the 0..1 space the shader samples.
struct AtlasTile {
    slot: i64,
    x: i64, y: i64,        // first texel of the tile inside the gutter
    w: i64, h: i64,        // texels of the tile (16x16, or 16x16n for an animation)
    u0: f32, v0: f32, u1: f32, v1: f32,
}

// Magic numbers of the layout, as fields so a test can reason about them.
struct AtlasLayout {
    tile: i64,      // texels per tile edge, 16
    gutter: i64,    // texels of copied edge around a tile, 1
    cols: i64,
    rows: i64,
    width: i64,
    height: i64,
    cells: i64,     // cols*rows
}

fn atlas_next_pow2(v: i64) -> i64 {
    var p: i64 = 1;
    while p < v { p = p * 2; }
    if p > 4096 { p = 4096; }
    return p;
}

// Plans an atlas for `count` tiles of `tile` texels with `gutter` texels of
// copied edge. The grid is as square as the count allows, and the image is the
// next power of two above the grid, padded on the right and bottom.
fn atlas_plan(count: i64, tile: i64, gutter: i64) -> AtlasLayout {
    var n = count;
    if n < 1 { n = 1; }
    if n > 4096 { n = 4096; }
    let cell = tile + gutter * 2;
    var cols: i64 = 1;
    while cols * cols < n { cols = cols + 1; }
    var rows = (n + cols - 1) / cols;
    let long_side = if cols > rows { cols } else { rows };
    let side = atlas_next_pow2(long_side * cell);
    return AtlasLayout {
        tile: tile, gutter: gutter, cols: cols, rows: rows,
        width: side, height: side, cells: cols * rows,
    };
}

// The texel origin of a slot, and the UV rect that stays inside the gutter.
fn atlas_tile(layout: AtlasLayout, slot: i64) -> AtlasTile {
    let cell = layout.tile + layout.gutter * 2;
    let cx = (slot % layout.cols) * cell;
    let cy = (slot / layout.cols) * cell;
    let x = cx + layout.gutter;
    let y = cy + layout.gutter;
    let fw = layout.width as f32;
    let fh = layout.height as f32;
    let tw = layout.tile as f32;
    return AtlasTile {
        slot: slot, x: x, y: y, w: layout.tile, h: layout.tile,
        u0: (x as f32) / fw,
        v0: (y as f32) / fh,
        u1: ((x as f32) + tw) / fw,
        v1: ((y as f32) + tw) / fh,
    };
}

// The loud tile. A magenta/black checker is unmistakable and compresses badly
// enough that nobody ships it by accident.
fn atlas_write_missing(atlas: u8[>..]&, layout: AtlasLayout, slot: i64) {
    let t = atlas_tile(layout, slot);
    for y in t.h {
        for x in t.w {
            let on = ((x / 4) + (y / 4)) % 2 == 0;
            let i = ((t.y + y) * layout.width + (t.x + x)) * 4;
            if on {
                atlas_set(atlas, i, 255, 0, 255, 255);
            } else {
                atlas_set(atlas, i, 0, 0, 0, 255);
            }
        }
    }
}

fn atlas_set(atlas: u8[>..]&, i: i64, r: u8, g: u8, b: u8, a: u8) {
    atlas[i] = r;
    atlas[i + 1] = g;
    atlas[i + 2] = b;
    atlas[i + 3] = a;
}

// Copies one source tile (rgba, `sw` x `sh`) into a slot, and then replicates its
// edge texels into the gutter all the way round.
//
// The source may be taller than wide: an animated texture is a vertical strip of
// square frames, and frame 0 is its top `sw` texels, which is what gets copied.
fn atlas_write_tile(atlas: u8[>..]&, layout: AtlasLayout, slot: i64, src: const u8[:],
                    sw: i64, sh: i64, frame0: bool) {
    let t = atlas_tile(layout, slot);
    var rows = t.h;
    if frame0 { rows = t.w; }               // an animation: only its first frame
    if sh < rows { rows = sh; }
    for y in rows {
        for x in t.w {
            let s = if x < sw { x } else { sw - 1 };
            let si = ((y) * sw + s) * 4;
            let di = ((t.y + y) * layout.width + (t.x + x)) * 4;
            atlas[di] = src[si];
            atlas[di + 1] = src[si + 1];
            atlas[di + 2] = src[si + 2];
            atlas[di + 3] = src[si + 3];
        }
    }
    // Fill the rest of the cell (a short tile, or a strip that ran out) with the
    // last row, so nothing in the cell is uninitialised.
    for y in rows..t.h {
        for x in t.w {
            let si = (((rows - 1) * sw) + (if x < sw { x } else { sw - 1 })) * 4;
            let di = ((t.y + y) * layout.width + (t.x + x)) * 4;
            atlas[di] = src[si];
            atlas[di + 1] = src[si + 1];
            atlas[di + 2] = src[si + 2];
            atlas[di + 3] = src[si + 3];
        }
    }
    atlas_replicate_gutter(atlas, layout, slot);
}

// Copies the tile's own edge texels one cell outwards. Doing it from the tile
// (not from the neighbour) is the point: the gutter belongs to this tile.
fn atlas_replicate_gutter(atlas: u8[>..]&, layout: AtlasLayout, slot: i64) {
    let t = atlas_tile(layout, slot);
    let g = layout.gutter;
    if g <= 0 { return; }
    for gy in g {
        for y in t.h {
            // left and right columns
            atlas_copy_texel(atlas, layout.width, t.x, t.y + y, t.x - g + gy, t.y + y);
            atlas_copy_texel(atlas, layout.width, t.x + t.w - 1, t.y + y, t.x + t.w + gy, t.y + y);
        }
        for x in t.w {
            // top and bottom rows
            atlas_copy_texel(atlas, layout.width, t.x + x, t.y, t.x + x, t.y - g + gy);
            atlas_copy_texel(atlas, layout.width, t.x + x, t.y + t.h - 1, t.x + x, t.y + t.h + gy);
        }
    }
    // The four corners, from the corner texel of the tile.
    for gy in g {
        for gx in g {
            atlas_copy_texel(atlas, layout.width, t.x, t.y, t.x - g + gx, t.y - g + gy);
            atlas_copy_texel(atlas, layout.width, t.x + t.w - 1, t.y, t.x + t.w + gx, t.y - g + gy);
            atlas_copy_texel(atlas, layout.width, t.x, t.y + t.h - 1, t.x - g + gx, t.y + t.h + gy);
            atlas_copy_texel(atlas, layout.width, t.x + t.w - 1, t.y + t.h - 1, t.x + t.w + gx, t.y + t.h + gy);
        }
    }
}

fn atlas_copy_texel(atlas: u8[>..]&, width: i64, sx: i64, sy: i64, dx: i64, dy: i64) {
    if dx < 0 || dy < 0 || dx >= width { return; }
    if (dy * width + dx) * 4 + 3 >= atlas.len { return; }
    let si = (sy * width + sx) * 4;
    let di = (dy * width + dx) * 4;
    atlas[di] = atlas[si];
    atlas[di + 1] = atlas[si + 1];
    atlas[di + 2] = atlas[si + 2];
    atlas[di + 3] = atlas[si + 3];
}

// The texel at (x, y) of a tile, for the on-device self-test: it draws a quad
// that samples exactly this texel through the production shader and compares the
// result with this function.
fn atlas_tile_texel(atlas: const u8[:], layout: AtlasLayout, slot: i64, x: i64, y: i64) -> i64 {
    let t = atlas_tile(layout, slot);
    // Bounds are checked against the tile, not only against the array: a coordinate
    // past the right edge would otherwise read the next row of the atlas and look
    // like a perfectly good pixel.
    if x < 0 || y < 0 || x >= t.w || y >= t.h { return -1; }
    if t.x + x >= layout.width { return -1; }
    let i = ((t.y + y) * layout.width + (t.x + x)) * 4;
    if i + 3 >= atlas.len { return -1; }
    return (atlas[i] as i64) | ((atlas[i + 1] as i64) << 8) | ((atlas[i + 2] as i64) << 16) |
           ((atlas[i + 3] as i64) << 24);
}

// A stable 32-bit hash of the whole atlas: two runs that produce the same image
// must report the same number, so a regression in the packer is visible in a log
// without shipping the image.
fn atlas_hash(atlas: const u8[:]) -> u32 {
    var h: u32 = 2166136261;
    for b in atlas {
        h = (h ^ (b as u32)) * 16777619;
    }
    return h;
}
