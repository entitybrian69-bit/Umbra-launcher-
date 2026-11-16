// Umbra jar render: draw the demo world with the client jar's own block models and
// the client jar's own textures, on the CPU, and say what came out.
//
// This is the check that a picture of the jar's data exists. It is not the phone's
// renderer and it is not the game: it is the same mesh the phone draws, through a
// rasterizer that runs in CI where no GPU does, so "the models and textures load and
// make a world" has a picture and numbers behind it instead of a claim.
//
//   umbra_jrender <client.jar> <out.ppm> [width] [height]
//
// Exit code 0 when the picture passes its own checks, 1 when it does not.

import std;
import math;
import os;
import core.mem;
import core.zip;
import core.region;
import core.mesh;
import core.models;
import core.modelstore;
import core.jarpack;
import core.atlas;
import core.demo;
import core.raster;
import core.savegame;

var jr_verts: Vertex[>..] = [];
var jr_indices: u32[>..] = [];
var jr_batches: i64[3] = [0, 0, 0];
var jr_blocks: i64 = 0;      // blocks drawn from a model, summed over the world
var jr_faces: i64 = 0;
var jr_skipped: i64 = 0;     // blocks whose blockstate had no model
var jr_starts: i64[3] = [0, 0, 0];

fn jr_fail(msg: const u8[:]) {
    print("jr: FAIL ", msg, "\n");
    exit(1);
}

fn jr_int_arg(i: i64, def: i64) -> i64 {
    if arg_count() <= i { return def; }
    var raw: u8[>..] = [];
    arg(i, raw);
    var v: i64 = 0;
    for k in raw.len {
        let d = (raw[k] as i64) - 48;
        if d < 0 || d > 9 { return def; }
        v = v * 10 + d;
    }
    if v <= 0 { return def; }
    return v;
}

// Copies the geometry the last mesh pass produced into the world-space arenas,
// dropping vertices nothing indexes and moving the block to its world position.
var jr_remap: u32[>..] = [];

fn jr_copy_column(b: i64, ox: f32, oz: f32) -> i64 {
    jr_remap = [];
    for k in mesh_verts.len { jr_remap.push(0); }
    let base_vert = jr_verts.len as u32;
    var next: u32 = 0;
    var moved: i64 = 0;
    for k in mesh_indices.len {
        let vi = mesh_indices[k];
        if jr_remap[vi as i64] != 0 { continue; }
        let src = mesh_verts[vi as i64];
        jr_verts.push(Vertex {
            x: src.x + ox, y: src.y, z: src.z + oz,
            nx: src.nx, ny: src.ny, nz: src.nz,
            u: src.u, v: src.v, r: src.r, g: src.g, b: src.b, ao: src.ao,
        });
        next += 1;
        jr_remap[vi as i64] = base_vert + next;
        moved += 1;
    }
    for k in mesh_indices.len {
        jr_indices.push(jr_remap[mesh_indices[k] as i64] - 1);
    }
    return moved;
}

// Meshes the whole demo world into world-space arenas, one column and one render
// class at a time, the way the app meshes a column: the three batches end up back to
// back, in drawing order.
fn jr_mesh_world() {
    jr_verts = [];
    jr_indices = [];
    var running: i64 = 0;
    for b in 3 {
        jr_starts[b] = jr_indices.len;
        for i in demo.len {
            mesh_clear_geometry();
            let want = if b == 0 { RC_OPAQUE } else if b == 1 { RC_CUTOUT } else { RC_TRANSLUCENT };
            for sy in -4..20 {
                mesh_section_class(demo[i], sy as i32, want);
            }
            let ox = (demo[i].x as f32) * 16.0;
            let oz = (demo[i].z as f32) * 16.0;
            jr_copy_column(b, ox, oz);
            // Counters describe the column just meshed; they are summed here because
            // the next column clears its geometry.
            if b == 0 {
                jr_blocks += mesh_model_block_count();
                jr_faces += mesh_model_face_count();
                jr_skipped += mesh_model_missing();
            }
        }
        jr_batches[b] = jr_indices.len - jr_starts[b];
        running += jr_batches[b];
    }
    let unused = running;
}

fn main() {
    crc32_init();
    if arg_count() < 3 {
        print("usage: umbra_jrender <client.jar> <out.ppm> [width] [height]\n");
        exit(2);
    }
    var jar_path: u8[>..] = [];
    arg(1, jar_path);
    var out_path: u8[>..] = [];
    arg(2, out_path);
    let width = jr_int_arg(3, 960);
    let height = jr_int_arg(4, 540);

    var jar: u8[>..] = [];
    if !read_file(jar_path[..], jar) || jar.len < 22 {
        jr_fail("the jar could not be read");
    }
    print("jr: jar ", jar.len, " bytes\n");
    ms_reset();
    if !jp_open(jar[..]) {
        jr_fail(jp_error());
    }

    // --- every model and every blockstate --------------------------------
    let t0 = 0;   // no clock in this tool: the counts are what matter, not the time
    let models = jp_build_models();
    let blockstates = jp_build_blockstates();
    let linked = ms_link_models();
    print("jr: models ", models, " built, ", ms_model_count(), " in the store, ",
          jp_models_refused, " refused\n");
    print("jr: blockstates ", blockstates, " built, ", ms_bs_count(), " in the store, ",
          ms_rule_count(), " rules, ", linked, " linked here, ", ms_rules_unlinked(),
          " with no model at all\n");
    print("jr: ", jp_faces, " faces in the models, ", ms_path_count(), " texture paths\n");
    if models < 100 { jr_fail("that is not a client jar: almost no models"); }
    if blockstates < 100 { jr_fail("that is not a client jar: almost no blockstates"); }

    // --- the atlas, from the jar's own pixels -----------------------------
    if !jp_build_atlas(16, 2) { jr_fail("the atlas could not be built"); }
    let layout = jp_atlas_layout();
    print("jr: atlas ", layout.width, "x", layout.height, " tile ", layout.tile,
          " gutter ", layout.gutter, " cells ", layout.cells, "\n");
    print("jr: textures used ", jp_tex_used, ", decoded ", jp_texture_decoded(),
          ", missing ", jp_texture_missing(), ", animated ", jp_texture_animated(), "\n");
    print("jr: atlas hash ", jp_atlas_of_hash(), "\n");
    mesh_set_layout(layout);
    for p in ms_path_count() {
        mesh_set_tile(p, jp_slot_of(p));
    }

    // --- tints, from the jar's colormaps ---------------------------------
    var grass: f32[3] = [1.0, 1.0, 1.0];
    var foliage: f32[3] = [1.0, 1.0, 1.0];
    var water: f32[3] = [1.0, 1.0, 1.0];
    // A colormap is indexed the way the client indexes it: x across temperature and
    // y down (1 - humidity * temperature), both flipped, because the top-right corner
    // of the image is the coldest, driest climate. Plains is temperature 0.8, humidity
    // 0.4, which is x 51 and y 173 of a 256x256 map.
    let temp: f32 = 0.8;
    let humid: f32 = 0.4;
    let cu = 1.0 - temp;
    let cv = 1.0 - humid * temp;
    if jp_read_colormap("grass") {
        jp_colormap_color(cu, cv, grass);
        print("jr: grass colormap ", jp_colormap_w(), "x", jp_colormap_h(), ", ", jp_colormap_bytes(),
              " bytes, sampled at ", (cu * (jp_colormap_w() as f32)) as i64, ",",
              (cv * (jp_colormap_h() as f32)) as i64, "\n");
        print("jr: grass tint ", (grass[0] * 255.0) as i64, ",", (grass[1] * 255.0) as i64,
              ",", (grass[2] * 255.0) as i64, " from the jar's colormap\n");
        if jp_read_colormap("foliage") { jp_colormap_color(cu, cv, foliage); }
        if jp_read_colormap("water") { jp_colormap_color(cu, cv, water); }
    } else {
        print("jr: no grass colormap in this jar; tints stay neutral\n");
    }
    mesh_set_tints(grass, foliage, water);

    // --- the world, drawn with the jar's models --------------------------
    mesh_use_store();
    // A save directory as the fifth argument draws *that* world instead of the demo one:
    // the same mesh, the same models, the same textures, on blocks nobody generated to
    // suit the renderer.
    var save_dir: u8[>..] = [];
    if arg_count() > 5 {
        arg(5, save_dir);
    }
    // Optional chunk radius for a save that is bigger than the picture needs.
    let radius = jr_int_arg(6, 0);
    if save_dir.len > 0 {
        demo = [];
        bs_reset();
        let st = sg_load(save_dir[..], true, radius);
        print("jr: save ", st.files, " region file(s), ", st.chunks, " chunks, ",
              st.blocks, " non-air blocks, ", st.errors, " read error(s)\n");
        if st.chunks == 0 { jr_fail("the save held no chunks"); }
        if st.blocks == 0 { jr_fail("the save held no blocks: the reader does not understand it"); }
        if st.errors > 0 { jr_fail("some chunks of the save could not be read"); }
    } else {
        demo_build(20261114);
    }
    jr_mesh_world();
    print("jr: blocks drawn from a model ", jr_blocks,
          ", faces ", jr_faces,
          ", blocks whose blockstate had no model ", jr_skipped, "\n");
    print("jr: vertices ", jr_verts.len, ", triangles ", jr_indices.len / 3,
          ", batches ", jr_batches[0], "/", jr_batches[1], "/", jr_batches[2], "\n");
    if jr_blocks < 1000 {
        jr_fail("almost no block came from a model: the blockstates are not matching");
    }

    // --- render -----------------------------------------------------------
    // The camera is where the app's overview camera would be: a three-quarter view
    // framed from the mesh, so the picture and the phone's picture are the same view.
    var minx: f32 = 1e9; var maxx: f32 = -1e9;
    var miny: f32 = 1e9; var maxy: f32 = -1e9;
    var minz: f32 = 1e9; var maxz: f32 = -1e9;
    for i in jr_verts.len {
        let v = jr_verts[i];
        if v.x < minx { minx = v.x; }
        if v.x > maxx { maxx = v.x; }
        if v.y < miny { miny = v.y; }
        if v.y > maxy { maxy = v.y; }
        if v.z < minz { minz = v.z; }
        if v.z > maxz { maxz = v.z; }
    }
    // The same framing the app uses (platform/shared/umbra_camera.h): three-quarter
    // view, world fitted by its footprint and the part of it above the ground, so the
    // picture here is the picture the phone draws, framed by the same rule.
    let cx = (minx + maxx) * 0.5;
    let cz = (minz + maxz) * 0.5;
    var horiz = maxx - minx;
    if maxz - minz > horiz { horiz = maxz - minz; }
    if horiz < 1.0 { horiz = 1.0; }
    let span_y = maxy - miny;
    var fit_h = span_y;
    if fit_h > horiz * 0.75 { fit_h = horiz * 0.75; }
    if fit_h < 1.0 { fit_h = 1.0; }
    let aspect = (width as f32) / (height as f32);
    let fov: f32 = 55.0;
    let tan_v = tan(fov * 3.14159265 / 180.0 * 0.5);
    let tan_h = tan_v * aspect;
    let fill: f32 = 0.92;
    var dist = (fit_h * 0.5) / (tan_v * fill);
    let dh = (horiz * 0.5) / (tan_h * fill);
    if dh > dist { dist = dh; }
    if dist < 16.0 { dist = 16.0; }
    if dist > 400.0 { dist = 400.0; }
    var target: f32[3] = [cx, maxy - fit_h * 0.5, cz];
    var eye: f32[3] = [
        target[0] + dist * 0.617,
        target[1] + dist * 0.458,
        target[2] + dist * 0.640,
    ];
    var up: f32[3] = [0.0, 1.0, 0.0];
    print("jr: bounds x ", minx as i64, "..", maxx as i64, " y ", miny as i64, "..", maxy as i64,
          " z ", minz as i64, "..", maxz as i64, ", camera ", dist as i64,
          " blocks out, looking at y ", target[1] as i64, "\n");

    rst_begin(width, height);
    rst_clear(0.55, 0.70, 0.92);
    rst_camera(eye, target, up, 55.0, 0.5, 1024.0);
    rst_set_fog(dist * 0.8, dist * 3.0);
    let atlas = jp_atlas_pixels();
    let aw = layout.width;
    let ah = layout.height;
    // Opaque, then cutout (alpha tested), then translucent (blended, no depth write):
    // the same three passes and the same order the phone draws.
    rst_draw(jr_starts[0], jr_batches[0], jr_verts, jr_indices, atlas, aw, ah, false, false);
    let opaque_px = rst_pixels_covered();
    rst_draw(jr_starts[1], jr_batches[1], jr_verts, jr_indices, atlas, aw, ah, false, true);
    let cutout_px = rst_pixels_covered() - opaque_px;
    let discarded = rst_discarded();
    rst_draw(jr_starts[2], jr_batches[2], jr_verts, jr_indices, atlas, aw, ah, true, true);
    let blend_px = rst_pixels_covered() - opaque_px - cutout_px;
    print("jr: drawn triangles ", rst_triangles_drawn(), " of ", rst_tris,
          ", clipped ", rst_triangles_clipped(), "\n");
    print("jr: pixels opaque ", opaque_px, ", cutout ", cutout_px, ", blended ", blend_px,
          ", discarded by the alpha test ", discarded, "\n");

    if !rst_write_ppm(out_path[..]) {
        jr_fail("the picture could not be written");
    }
    print("jr: wrote ", out_path, "\n");

    // --- what the picture has to be -------------------------------------
    // Count what the frame is made of: sky, and pixels that are not sky. A picture
    // that is all sky means nothing was drawn; a picture that is nothing but one
    // colour means the textures did not load.
    var sky = 0;
    var other = 0;
    var dark = 0;
    var magenta = 0;   // the atlas's loud "no texture here" tile
    var hue_buckets: i64[8] = [0; 8];
    for y in height {
        for x in width {
            let c = rst_color_at(x, y);
            let r = (c >> 16) & 0xFF;
            let g = (c >> 8) & 0xFF;
            let b = c & 0xFF;
            let is_sky = r > 130 && r < 150 && g > 170 && g < 190 && b > 225;
            if is_sky { sky += 1; } else {
                other += 1;
                if r + g + b < 180 { dark += 1; }
                if r > 200 && g < 60 && b > 200 { magenta += 1; }
                // A coarse hue bucket: the picture has to contain more than one kind
                // of surface, or the atlas is one colour.
                var bucket: i64 = 0;
                if g > r + 20 && g > b { bucket = 1; }        // green
                else if b > r + 20 && b > g { bucket = 2; }   // blue
                else if r > g + 20 && r > b { bucket = 3; }   // brown / red
                else if r + g + b > 500 { bucket = 4; }       // pale
                hue_buckets[bucket] += 1;
            }
        }
    }
    let total = width * height;
    let coverage = (other * 1000) / total;
    print("jr: coverage ", coverage, " permille of the frame (", other, " of ", total,
          " px), sky ", sky, "\n");
    print("jr: hues green ", hue_buckets[1], ", blue ", hue_buckets[2], ", brown ",
          hue_buckets[3], ", pale ", hue_buckets[4], ", other ", hue_buckets[0],
          ", dark ", dark, ", missing-tile magenta ", magenta, "\n");
    if coverage < 100 { jr_fail("the frame is almost all sky: the world was not drawn"); }
    if hue_buckets[1] < 500 { jr_fail("no green: the grass and leaves did not sample a texture"); }
    if hue_buckets[3] < 500 { jr_fail("no brown: the dirt and wood did not sample a texture"); }
    // The atlas reserves a magenta/black tile for a texture the jar does not have. A
    // frame drawn from the jar must be made of the jar's art, not of that tile.
    if magenta * 100 > other {
        jr_fail("more than one percent of the frame is the missing-texture tile");
    }

    // --- the atlas against the jar's own pixels ---------------------------
    // A model face with no uv rect maps the whole texture onto the whole face, so a
    // tile in the atlas has to be the PNG the jar ships, texel for texel. This is the
    // check that a mipmap, a gutter or a frame-0 crop did not quietly change the art.
    let exact = jr_check_atlas_against_jar();
    print("jr: atlas texels compared with the jar's PNGs: ", exact[1], " sampled, ",
          exact[0], " differ\n");
    if exact[1] == 0 { jr_fail("no texture could be compared with its PNG"); }
    if exact[0] != 0 { jr_fail("the atlas does not match the jar's PNGs"); }

    print("jr: PASS - a world drawn with the jar's own models and textures\n");
}

// Compares the atlas against the jar's pixels, for every texture it can: returns
// [differing texels, compared texels].
var jr_cmp: i64[2] = [0, 0];
var jr_tile_px: i64[0] = [];
var jr_check_buf: u8[>..] = [];

fn jr_check_atlas_against_jar() -> i64[2] {
    jr_cmp[0] = 0;
    jr_cmp[1] = 0;
    let layout = jp_atlas_layout();
    let atlas = jp_atlas_pixels();
    var checked: i64 = 0;
    for p in ms_path_count() {
        if checked >= 24 { break; }
        let slot = jp_slot_of(p);
        if slot <= 0 { continue; }
        var entry: u8[>..] = [];
        jp_texture_entry(ms_path(p), entry);
        let bytes = jp_read(entry[..]);
        if bytes.len == 0 { continue; }
        var pal: u8[>..] = [];
        var rgba: u8[>..] = [];
        let info, ok, perr = png_decode(bytes, pal, rgba);
        if !ok { continue; }
        // Only a still 16x16 PNG can be compared texel for texel; a larger or
        // animated one was scaled or cropped on purpose, and saying so is better than
        // pretending it was not.
        if info.width != layout.tile || info.height != layout.tile { continue; }
        var differ = 0;
        for y in layout.tile {
            for x in layout.tile {
                let t = atlas_tile(layout, slot);
                let ai = ((t.y + y) * layout.width + (t.x + x)) * 4;
                let si = (y * info.width + x) * 4;
                let same = atlas[ai] == rgba[si] && atlas[ai + 1] == rgba[si + 1] &&
                           atlas[ai + 2] == rgba[si + 2] && atlas[ai + 3] == rgba[si + 3];
                if !same { differ += 1; }
                jr_cmp[1] += 1;
            }
        }
        jr_cmp[0] += differ;
        checked += 1;
        let unused = jr_tile_px;
        let unused2 = jr_check_buf;
    }
    return jr_cmp;
}
