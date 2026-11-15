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
import core.textures;
import core.atlas;

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

// --- meshing, in slices ------------------------------------------------
//
// Meshing the demo world takes seconds on a phone, and a phone that blocks its
// frame loop for seconds gets an "app isn't responding" dialog. The work is
// therefore a resumable state machine: the C frame loop calls demo_mesh_step()
// with a time budget, and each call completes as many sections as fit. The
// result is byte-identical to meshing everything at once, which is what
// tools/run_tests.sh checks.

// The budget is measured on this side, so one call cannot overrun it by much.
extern fn umbra_c_now_us() -> i64 = "umbra_c_now_us";

var dm_state: i64 = 0;   // 0 not begun, 1 running, 2 done
var dm_b: i64 = 0;       // batch pass
var dm_col: i64 = 0;     // column
var dm_pass: i64 = 0;    // one of the column's three passes
var dm_sy: i64 = -4;     // section y within the column
var dm_running: i64 = 0; // indices emitted so far, for world_starts
var dm_units: i64 = 0;   // sections (and copies) completed
var dm_worst_unit_us: i64 = 0;

fn demo_mesh_begin() {
    world_verts = [];
    world_indices = [];
    for b in 3 {
        world_starts[b] = 0;
        world_batches[b] = 0;
    }
    dm_state = 1;
    dm_b = 0;
    dm_col = 0;
    dm_pass = 0;
    dm_sy = -4;
    dm_running = 0;
    dm_units = 0;
    dm_worst_unit_us = 0;
}

// One batch's slice of one column, copied into world space. This is the tail of
// the old per-column loop, unchanged apart from its inputs.
fn demo_copy_column(b: i64, i: i64) {
    let base_vert = (world_verts.len as u32);
    let start_idx = if b == 0 { 0 } else if b == 1 { batch_starts[1] } else { batch_starts[2] };
    let count = batch_counts[b];
    if count <= 0 { return; }
    let ox = (demo[i].x as f32) * 16.0;
    let oz = (demo[i].z as f32) * 16.0;
    var remap: u32[65536] = [0; 65536];
    var next: u32 = 0;
    for k in count {
        let vi = mesh_indices[start_idx + k];
        if remap[vi as i64] == 0 {
            let src = mesh_verts[vi as i64];
            world_verts.push(Vertex {
                x: src.x + ox, y: src.y + oz, z: src.z,
                nx: src.nx, ny: src.ny, nz: src.nz,
                u: src.u, v: src.v, r: src.r, g: src.g, b: src.b, ao: src.ao,
            });
            next += 1;
            remap[vi as i64] = base_vert + next;
        }
        world_indices.push(remap[vi as i64] - 1);
    }
}

// One section of one pass of one column, or the copy that closes a column.
fn demo_mesh_unit() {
    if dm_state != 1 { return; }
    if dm_col >= demo.len {
        world_batches[dm_b] = dm_running - world_starts[dm_b];
        dm_b += 1;
        dm_col = 0;
        dm_pass = 0;
        dm_sy = -4;
        if dm_b >= 3 { dm_state = 2; }
        return;
    }
    // A fresh column starts with an empty mesh arena.
    if dm_pass == 0 && dm_sy == -4 { mesh_reset(); }
    if dm_sy == -4 {
        if dm_pass == 0 && dm_col == 0 { world_starts[dm_b] = dm_running; }
        batch_starts[dm_pass] = mesh_indices.len;
    }
    let want = if dm_pass == 0 { RC_OPAQUE } else if dm_pass == 1 { RC_CUTOUT } else { RC_TRANSLUCENT };
    mesh_section_class(demo[dm_col], dm_sy as i32, want);
    dm_sy += 1;
    if dm_sy <= 19 { return; }
    // That pass is finished.
    batch_counts[dm_pass] = mesh_indices.len - batch_starts[dm_pass];
    dm_sy = -4;
    dm_pass += 1;
    if dm_pass < 3 { return; }
    dm_pass = 0;
    demo_copy_column(dm_b, dm_col);
    dm_running += batch_counts[dm_b];
    dm_col += 1;
}

// Runs units until the budget is spent. Returns true when the mesh is complete.
fn demo_mesh_step(budget_us: i64) -> bool {
    if dm_state != 1 { return true; }
    let start = umbra_c_now_us();
    while dm_state == 1 {
        let unit_start = umbra_c_now_us();
        demo_mesh_unit();
        let unit_us = umbra_c_now_us() - unit_start;
        if unit_us > dm_worst_unit_us { dm_worst_unit_us = unit_us; }
        dm_units += 1;
        if umbra_c_now_us() - start >= budget_us { break; }
    }
    return dm_state == 2;
}

// Meshing everything in one call, for the tools and the headless host.
fn demo_mesh() {
    demo_mesh_begin();
    while !demo_mesh_step(1000000) { }
    serialize_mesh();
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

// Where and what the first mismatch was. A count alone ("2458665 bad") does not
// say whether the driver is off by one in a blended corner or drawing something
// else entirely; these six numbers do, and they travel in the shared log.
var st_bad_text: u8[>..] = [];

fn st_note_bad(x: i64, y: i64, r: i64, g: i64, b: i64, wr: i64, wg: i64, wb: i64) {
    if st_first_bad >= 0 { return; }
    st_first_bad = y * 4096 + x;
    st_bad_text = [];
    format(st_bad_text, "at ", x, ",", y, " got ", r, ",", g, ",", b, " want ", wr, ",", wg, ",", wb);
}

export "umbra_selftest_first_bad_text" fn st_first_bad_text() -> const u8[:] {
    return st_bad_text;
}

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
    st_bad_text = [];
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
        st_note_bad(x, y, r, g, b, want[0], want[1], want[2]);
    }
}

fn st_check_cube_pixel(x: i64, y: i64, w: i64, h: i64, r: i64, g: i64, b: i64) {
    st_checked += 1;
    // The cube is dead centre: a 1x1x1 cube at the origin seen from z = 3 with
    // a 60 degree vertical field of view covers |dx| and |dy| up to about
    // 0.347 * h/2 = h/6 in pixels. The test only judges the parts it is sure
    // about: h/8 inside (must be cube) and h/4 outside (must be background).
    // Anything between is the cube's own edge and is not judged.
    //
    // The faces are shaded by the same light values the mesher uses, so a wrong
    // depth range or a transposed matrix puts the background colour in the
    // middle and fails here.
    let cx = w / 2;
    let cy = h / 2;
    let dx = abs(x - cx);
    let dy = abs(y - cy);
    let m = if h < w { h } else { w };
    let inside = dx < m / 8 && dy < m / 8;
    let outside = dx > m / 4 || dy > m / 4;
    let is_background = r < 30 && g < 40 && b < 60;
    if inside && is_background {
        st_mismatches += 1;
        st_note_bad(x, y, r, g, b, 255, 255, 255);
    }
    if outside && !is_background {
        // Beyond the cube's silhouette there must be nothing but the clear colour.
        st_mismatches += 1;
        st_note_bad(x, y, r, g, b, 5, 7, 15);
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

fn format_ms(out: u8[>..]&, us: i64) {
    // Microseconds as milliseconds with exactly two decimals: a value that
    // prints sometimes as "16.0" and sometimes as "16.83" is hard to compare.
    let tenths = (us % 1000) / 100;
    format(out, us / 1000, ".", tenths, (us % 100) / 10);
}

fn bench_summary(out: u8[>..]&, label: const u8[:], device: const u8[:], android: const u8[:],
                 gpu_us: i64, gpu_supported: i64, uncapped: i64, gpu_frames: i64) {
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
    // Four short lines, not one long one: this is drawn on a phone screen, and
    // the numbers a tester must read (average, 1% low, worst) each get a line.
    format(out, label, ": ", n, " frames");
    format(out, "  avg ");
    format_ms(out, avg);
    format(out, " ms (", if avg > 0 { 1000000 / avg } else { 0 }, " fps)");
    format(out, "\n1% low ", if p1 > 0 { 1000000 / p1 } else { 0 }, " fps (");
    format_ms(out, p1);
    format(out, " ms)");
    format(out, "\nmedian ");
    format_ms(out, median);
    format(out, " ms  worst ");
    format_ms(out, worst);
    format(out, " ms");
    format(out, "\n", device, " | Android ", android);
    // Frame time and GPU time are different questions: a 60 Hz display caps the
    // first at 16.7 ms whatever the GPU does, which is why the owner's 59 FPS told
    // us nothing. The second is measured with a timer query around the draw.
    if gpu_supported == 0 {
        format(out, "\ngpu n/a (no GPU timer results)");
    } else if gpu_frames <= 0 {
        format(out, "\ngpu: queried, no result before the end");
    } else {
        format(out, "\ngpu avg ");
        format_ms(out, gpu_us / gpu_frames);
        format(out, " ms over ", gpu_frames, " frames");
    }
    format(out, "\nvsync: ");
    if uncapped == 1 {
        format(out, "uncapped requested");
    } else if uncapped == 2 {
        format(out, "uncapped refused");
    } else {
        format(out, "capped by the platform");
    }
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
                                                     android: const u8[:], gpu_us: i64,
                                                     gpu_supported: i64, uncapped: i64,
                                                     gpu_frames: i64) -> const u8[:] {
    bench_text = [];
    bench_summary(bench_text, label, device, android, gpu_us, gpu_supported, uncapped, gpu_frames);
    return bench_text;
}

export "umbra_demo_build" fn demo_build_export(seed: i64) { demo_build(seed) }
export "umbra_demo_mesh" fn demo_mesh_export() { demo_mesh(); serialize_mesh() }

// The sliced path: begin, step with a budget until it returns 1, then finish.
export "umbra_demo_mesh_begin" fn demo_mesh_begin_export() { demo_mesh_begin() }
export "umbra_demo_mesh_step" fn demo_mesh_step_export(budget_us: i64) -> i64 {
    return if demo_mesh_step(budget_us) { 1 } else { 0 }
}
export "umbra_demo_mesh_finish" fn demo_mesh_finish_export() { serialize_mesh() }
// Progress in permille, for the loading screen.
// How many units the whole mesh takes. Counted from the same structure the
// stepper walks, because the first version of this was wrong and showed the
// owner "LOADING WORLD 224%": three batches, each with every column's three
// passes of 24 sections, plus the one unit that closes the batch. Copying a
// column into world space happens inside the last section's unit, which the
// headless check `units == total` proves by comparing the two numbers.
export fn umbra_demo_mesh_total_units() -> i64 {
    let per_batch = demo.len * 3 * 24 + 1;
    return per_batch * 3;
}

export "umbra_demo_mesh_progress" fn demo_mesh_progress() -> i64 {
    if dm_state == 2 { return 1000; }
    if dm_state == 0 { return 0; }
    let total = umbra_demo_mesh_total_units();
    if total <= 0 { return 1000; }
    let p = (dm_units * 1000) / total;
    // A phone shows "LOADING WORLD 224%": clamp as well as fix the divisor, so a
    // future miscount cannot reach the screen as nonsense.
    if p < 0 { return 0; }
    if p > 1000 { return 1000; }
    return p;
}
export fn umbra_demo_mesh_units() -> i64 { return dm_units }
export fn umbra_demo_mesh_worst_unit_us() -> i64 { return dm_worst_unit_us }

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
// --- the atlas, for the renderer ---------------------------------------
//
// The pixel buffer belongs to Goose; C uploads it to one GL texture and the
// vertices carry UVs inside it. Nothing here is Mojang art: see
// core/textures.goose and DECISIONS.md D-039.

export "umbra_atlas_build" fn atlas_build_export() { tex_build() }
export "umbra_atlas_pixels" fn atlas_pixels() -> const u8[:] { tex_build(); return tex_atlas }
export "umbra_atlas_size" fn atlas_size() -> i64 { return tex_atlas_size() }
export "umbra_atlas_height" fn atlas_height() -> i64 { return tex_atlas_height() }
export "umbra_atlas_hash" fn atlas_hash_export() -> u32 { return tex_atlas_hash() }
export "umbra_atlas_missing" fn atlas_missing() -> i64 { return tex_missing_count() }
export "umbra_atlas_tiles" fn atlas_tiles() -> i64 { return TEX_COUNT }
export "umbra_atlas_tile_u0" fn atlas_u0(slot: i64) -> f32 { return tex_uv(slot)[0] }
export "umbra_atlas_tile_v0" fn atlas_v0(slot: i64) -> f32 { return tex_uv(slot)[1] }
export "umbra_atlas_tile_u1" fn atlas_u1(slot: i64) -> f32 { return tex_uv(slot)[2] }
export "umbra_atlas_tile_v1" fn atlas_v1(slot: i64) -> f32 { return tex_uv(slot)[3] }
export "umbra_atlas_texel" fn atlas_texel(slot: i64, x: i64, y: i64) -> i64 {
    return tex_texel(slot, x, y)
}
export "umbra_atlas_named" fn atlas_named(name: const u8[:]) -> i64 {
    return tex_slot_for(name)
}

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
