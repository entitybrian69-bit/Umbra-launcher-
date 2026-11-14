// Umbra's core library: the entry the C platform layer links against.
//
// The C side owns the window, the GL context, input and files. Everything that
// decides what the game *does* -- formats, world data, meshing, the self-test's
// expected results, benchmark statistics -- lives here in Goose and is called
// through the exports at the bottom of this file.
//
// Built with:
//   goose --standalone --header umbra_core.h -o umbra_core.c goose/main.goose
// The host calls goose_init() once, then any export. Exports are not
// thread-safe: call them from the thread that called goose_init().

import std;
import core.mem;
import core.inflate;
import core.zip;
import core.png;
import core.nbt;
import core.region;
import core.mesh;

let UMBRA_VERSION = "0.1.0-stage1";

// --- a demo world ------------------------------------------------------
//
// Until the jar's own data is imported, the demo scene is generated here in
// Goose so the renderer has real mesh data to draw: rolling terrain with grass,
// dirt and stone, a pond, trees and plants. It is not worldgen parity; it is a
// scene that exercises every mesh batch.

var demo: ChunkColumn[>..] = [];

fn demo_height(x: i64, z: i64) -> i64 {
    // Cheap value noise, smoothed, so the terrain has hills without a noise
    // module yet.
    let sx = ((x * 13 + z * 7) % 11) - 5;
    let sz = ((x * 5 + z * 17) % 13) - 6;
    return 64 + (sx * sx) / 6 - (sz * sz) / 9;
}

fn demo_build(seed: i64) {
    bs_reset();
    let stone = bs_intern("minecraft:stone", "");
    let dirt = bs_intern("minecraft:dirt", "");
    let grass = bs_intern("minecraft:grass_block", "snowy=false");
    let water = bs_intern("minecraft:water", "level=0");
    let log = bs_intern("minecraft:oak_log", "axis=y");
    let leaves = bs_intern("minecraft:oak_leaves", "distance=7");
    let plant = bs_intern("minecraft:short_grass", "half=bottom");
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
                }
            }
            demo.push(c);
        }
    }
}

// Mesh every column of the demo world into one set of arenas, offsetting each
// column's vertices to its world position.
var world_verts: Vertex[>..] = [];
var world_indices: u32[>..] = [];
var world_batches: i64[3] = [0, 0, 0];
var world_starts: i64[3] = [0, 0, 0];

fn demo_mesh() {
    world_verts = [];
    world_indices = [];
    for b in 3 {
        world_starts[b] = 0;
        world_batches[b] = 0;
    }
    // Pass per batch so each batch is one contiguous index range.
    var running: i64 = 0;
    for b in 3 {
        world_starts[b] = running;
        for i in demo.len {
            mesh_column(demo[i]);
            // Copy this column's slice of the batch, offset to world space.
            let base_vert = (world_verts.len as u32);
            let start_idx = if b == 0 { 0 } else if b == 1 { batch_starts[1] } else { batch_starts[2] };
            let count = batch_counts[b];
            // Copy only the vertices the batch's indices use.
            var max_vert: u32 = 0;
            for k in count {
                let vi = mesh_indices[start_idx + k];
                if vi > max_vert { max_vert = vi; }
            }
            if count > 0 {
                let ox = (demo[i].x as f32) * 16.0;
                let oz = (demo[i].z as f32) * 16.0;
                var remap: u32[65536] = [0; 65536];
                var next: u32 = 0;
                for k in count {
                    let vi = mesh_indices[start_idx + k];
                    if remap[vi as i64] == 0 {
                        let src = mesh_verts[vi as i64];
                        world_verts.push(Vertex {
                            x: src.x + ox, y: src.y, z: src.z + oz,
                            nx: src.nx, ny: src.ny, nz: src.nz,
                            u: src.u, v: src.v, r: src.r, g: src.g, b: src.b, ao: src.ao,
                        });
                        next += 1;
                        remap[vi as i64] = base_vert + next;
                    }
                    world_indices.push(remap[vi as i64] - 1);
                }
            }
            running += count;
        }
        world_batches[b] = running - world_starts[b];
    }
}

// --- the GPU self-test -------------------------------------------------
//
// The C side draws and reads pixels back; the expected colours and the
// verdict are computed here, so the logic under test is the Goose code that
// ships rather than a copy of it in C.
//
// Pattern test: a fullscreen quad whose fragment colour is a pure function of
// gl_FragCoord, compared pixel by pixel against the same function in Goose.
// That catches a wrong viewport, a wrong attribute layout and a wrong blend
// state. A 3D cube test then catches matrix and depth-range mistakes.

var st_mismatches: i64 = 0;
var st_checked: i64 = 0;
var st_max_diff: i64 = 0;
var st_first_bad: i64 = -1;

fn pattern_expected(x: i64, y: i64, w: i64, h: i64) -> i64[3] {
    // Keep this in step with the fragment shader in platform/shared/umbra_app.c.
    let u = (x * 255) / (if w > 1 { w - 1 } else { 1 });
    let v = (y * 255) / (if h > 1 { h - 1 } else { 1 });
    return [(u ^ v) & 0xFF, (u + v) & 0xFF, 64];
}

fn st_reset() {
    st_mismatches = 0;
    st_checked = 0;
    st_max_diff = 0;
    st_first_bad = -1;
}

// Called once per pixel with the framebuffer's value, bottom-left origin as
// glReadPixels returns it.
fn st_check_pattern_pixel(x: i64, y: i64, w: i64, h: i64, r: i64, g: i64, b: i64) {
    let want = pattern_expected(x, y, w, h);
    var d: i64 = abs(r - want[0]);
    if abs(g - want[1]) > d { d = abs(g - want[1]); }
    if abs(b - want[2]) > d { d = abs(b - want[2]); }
    st_checked += 1;
    if d > st_max_diff { st_max_diff = d; }
    // Software GL (the CI emulator's swiftshader) is exact for this shader;
    // allow one step for rounding on real drivers.
    if d > 1 {
        st_mismatches += 1;
        if st_first_bad < 0 { st_first_bad = y * w + x; }
    }
}

fn st_check_cube_pixel(x: i64, y: i64, w: i64, h: i64, r: i64, g: i64, b: i64) {
    st_checked += 1;
    // The cube is dead centre. Its faces are shaded by the same light values
    // the mesher uses, so a wrong depth range or a transposed matrix puts the
    // background colour in the middle and fails here.
    let cx = w / 2;
    let cy = h / 2;
    let dx = abs(x - cx);
    let dy = abs(y - cy);
    let inside = dx * 2 < w / 3 && dy * 2 < h / 3;
    let is_background = r < 30 && g < 40 && b < 60;
    if inside && is_background {
        st_mismatches += 1;
        if st_first_bad < 0 { st_first_bad = y * w + x; }
    }
    if !inside && !is_background {
        // Outside the cube there must be nothing but the clear colour.
        st_mismatches += 1;
        if st_first_bad < 0 { st_first_bad = y * w + x; }
    }
}

// --- benchmark statistics ----------------------------------------------

var frame_us: i64[>..] = [];
var bench_started = false;

fn bench_reset() {
    frame_us = [];
    bench_started = true;
}

fn bench_add(us: i64) {
    frame_us.push(us);
}

fn bench_summary(out: u8[>..]&, label: const u8[:], device: const u8[:], android: const u8[:]) {
    let n = frame_us.len;
    if n == 0 {
        format(out, label, ": no frames measured");
        return;
    }
    var total: i64 = 0;
    var worst: i64 = 0;
    for v in frame_us {
        total += v;
        if v > worst { worst = v; }
    }
    let avg = total / n;
    // 1% low: the mean of the slowest 1% of frames, the usual definition.
    var sorted: i64[>..] = [];
    for v in frame_us { sorted.push(v); }
    sort_i64(sorted);
    let p1n = if n / 100 > 0 { n / 100 } else { 1 };
    var p1sum: i64 = 0;
    for i in p1n { p1sum += sorted[sorted.len - 1 - i]; }
    let p1 = p1sum / p1n;
    let median = sorted[n / 2];
    format(out, label, ": ", n, " frames");
    format(out, " avg ", avg / 1000, ".", (avg % 1000) / 10, " ms (",
           if avg > 0 { 1000000 / avg } else { 0 }, " fps)");
    format(out, " 1% low ", p1 / 1000, ".", (p1 % 1000) / 10, " ms");
    format(out, " median ", median / 1000, ".", (median % 1000) / 10, " ms");
    format(out, " worst ", worst / 1000, ".", (worst % 1000) / 10, " ms");
    format(out, " | ", device, " | Android ", android);
}

fn sort_i64(xs: i64[>..]&) {
    // Insertion sort is fine for a few thousand frame times and keeps this
    // free of any library dependency; swap to a real sort if the window grows.
    var i = 1;
    while i < xs.len {
        let v = xs[i];
        var j = i - 1;
        while j >= 0 && xs[j] > v {
            xs[j + 1] = xs[j];
            j -= 1;
        }
        xs[j + 1] = v;
        i += 1;
    }
}

// --- exported API ------------------------------------------------------

export fn umbra_version() -> const u8[:] { return UMBRA_VERSION }

export "umbra_selftest_reset" fn selftest_reset() { st_reset() }

export "umbra_selftest_pattern_pixel" fn st_pattern(x: i64, y: i64, w: i64, h: i64,
                                                   r: i64, g: i64, b: i64) {
    st_check_pattern_pixel(x, y, w, h, r, g, b);
}

export "umbra_selftest_cube_pixel" fn st_cube(x: i64, y: i64, w: i64, h: i64,
                                              r: i64, g: i64, b: i64) {
    st_check_cube_pixel(x, y, w, h, r, g, b);
}

export fn umbra_selftest_mismatches() -> i64 { return st_mismatches }
export fn umbra_selftest_checked() -> i64 { return st_checked }
export fn umbra_selftest_max_diff() -> i64 { return st_max_diff }
export fn umbra_selftest_first_bad() -> i64 { return st_first_bad }

export "umbra_bench_reset" fn bench_reset_export() { bench_reset() }
export "umbra_bench_add" fn bench_add_export(us: i64) { bench_add(us) }
export "umbra_bench_frames" fn bench_frames() -> i64 { return frame_us.len }

// A benchmark line for the HUD, formatted in Goose and handed to C as text.
var bench_text: u8[>..] = [];

export "umbra_bench_summary" fn bench_summary_export(label: const u8[:], device: const u8[:],
                                                     android: const u8[:]) -> const u8[:] {
    bench_text = [];
    bench_summary(bench_text, label, device, android);
    return bench_text;
}

export "umbra_demo_build" fn demo_build_export(seed: i64) { demo_build(seed) }
export "umbra_demo_mesh" fn demo_mesh_export() { demo_mesh(); serialize_mesh() }

// Serialised copies of the mesh, in the exact byte layout the GPU wants:
// 12 little-endian f32 per vertex, 4 little-endian u32 per index. Goose has no
// pointer casts, so the conversion is explicit; it runs once per mesh build.
var vert_bytes: u8[>..] = [];
var index_bytes: u8[>..] = [];

fn put_f32_le(out: u8[>..]&, v: f32) {
    let bits = umbra_c_bits_of_f32(v);
    out.push((bits & 0xFF) as u8);
    out.push(((bits >> 8) & 0xFF) as u8);
    out.push(((bits >> 16) & 0xFF) as u8);
    out.push(((bits >> 24) & 0xFF) as u8);
}

fn serialize_mesh() {
    vert_bytes = [];
    index_bytes = [];
    for i in world_verts.len {
        let v = world_verts[i];
        put_f32_le(vert_bytes, v.x);
        put_f32_le(vert_bytes, v.y);
        put_f32_le(vert_bytes, v.z);
        put_f32_le(vert_bytes, v.nx);
        put_f32_le(vert_bytes, v.ny);
        put_f32_le(vert_bytes, v.nz);
        put_f32_le(vert_bytes, v.u);
        put_f32_le(vert_bytes, v.v);
        put_f32_le(vert_bytes, v.r);
        put_f32_le(vert_bytes, v.g);
        put_f32_le(vert_bytes, v.b);
        put_f32_le(vert_bytes, v.ao);
    }
    for i in world_indices.len {
        let v = world_indices[i];
        index_bytes.push((v & 0xFF) as u8);
        index_bytes.push(((v >> 8) & 0xFF) as u8);
        index_bytes.push(((v >> 16) & 0xFF) as u8);
        index_bytes.push(((v >> 24) & 0xFF) as u8);
    }
}

export "umbra_verts_ptr" fn world_verts_ptr() -> const u8[:] { return vert_bytes }
export "umbra_indices_ptr" fn world_indices_ptr() -> const u8[:] { return index_bytes }
export "umbra_vert_count" fn world_vert_count() -> i64 { return world_verts.len }
export "umbra_index_count" fn world_index_count() -> i64 { return world_indices.len }
export "umbra_batch_start" fn world_batch_start(b: i64) -> i64 { return world_starts[b] }
export "umbra_batch_count" fn world_batch_count(b: i64) -> i64 { return world_batches[b] }

// A world-space AABB of the demo mesh, so the C camera can frame it without
// duplicating the layout knowledge.
export "umbra_mesh_min_x" fn mesh_min_x() -> f32 { return mesh_bound(0, true) }
export "umbra_mesh_max_x" fn mesh_max_x() -> f32 { return mesh_bound(0, false) }
export "umbra_mesh_min_y" fn mesh_min_y() -> f32 { return mesh_bound(1, true) }
export "umbra_mesh_max_y" fn mesh_max_y() -> f32 { return mesh_bound(1, false) }
export "umbra_mesh_min_z" fn mesh_min_z() -> f32 { return mesh_bound(2, true) }
export "umbra_mesh_max_z" fn mesh_max_z() -> f32 { return mesh_bound(2, false) }

fn mesh_bound(axis: i64, want_min: bool) -> f32 {
    if world_verts.len == 0 { return 0.0; }
    var best: f32 = if want_min { 1.0e9 } else { -1.0e9 };
    for i in world_verts.len {
        let v = world_verts[i];
        let value = if axis == 0 { v.x } else if axis == 1 { v.y } else { v.z };
        if want_min { if value < best { best = value; } }
        else { if value > best { best = value; } }
    }
    return best;
}

// A log line for the crash marker and the Share log button.
export "umbra_core_selftest_name" fn core_selftest_name() -> const u8[:] {
    return "umbra core: formats and meshing";
}
