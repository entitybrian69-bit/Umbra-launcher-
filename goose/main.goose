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
import os;
import core.mem;
import core.inflate;
import core.zip;
import core.png;
import core.nbt;
import core.region;
import core.mesh;
import core.textures;
import core.atlas;
import core.models;
import core.modelstore;
import core.jarpack;
import core.demo;
import core.sha1;
import core.gamefiles;

let UMBRA_VERSION = "0.3.7";

// --- a demo world ------------------------------------------------------
//
// Until the jar's own data is imported, the demo scene is generated here in
// Goose so the renderer has real mesh data to draw: rolling terrain with grass,
// dirt and stone, a pond, trees and plants. It is not worldgen parity; it is a
// scene that exercises every mesh batch.


// --- where the world's geometry lives -----------------------------------
//
// The world is meshed into one vertex arena and one index arena, but not as one
// undifferentiated mass: every (batch, column) pair owns a *slot*, a range of both
// arenas with a little slack. That is what lets an edit re-mesh the one column it
// touched instead of the world, which is the rule the current brief sets
// ("re-meshing after an edit must not rebuild the world").
//
// Indices are absolute (they point into the vertex arena), so a slot can be drawn
// without touching the vertex attribute pointers: one glDrawElements per slot, with
// the slot's index range as the offset. The slack is there so a column whose face
// count grows by a few can be rewritten where it sits; a column that outgrows its
// slot moves to the end of the arena and the whole buffers are re-uploaded, which
// the log counts because it is the case worth noticing.
var world_verts: Vertex[>..] = [];
var world_indices: u32[>..] = [];

var sl_col: i64[>..] = [];     // slot -> column index in demo
var sl_batch: i64[>..] = [];   // slot -> 0 opaque, 1 cutout, 2 translucent
var sl_v_off: i64[>..] = [];   // slot -> first vertex in world_verts
var sl_v_cap: i64[>..] = [];   // slot -> vertices reserved
var sl_v_len: i64[>..] = [];   // slot -> vertices used
var sl_i_off: i64[>..] = [];   // slot -> first index in world_indices
var sl_i_cap: i64[>..] = [];
var sl_i_len: i64[>..] = [];

// What changed since the last upload: slot ids. `dm_moved` means the arena itself
// changed length, so every byte has to go up again.
var dm_dirty: i64[>..] = [];
var dm_moved: bool = false;

// The columns the last edit touched, for the log and for the stepper.
var edit_cols: i64[>..] = [];

// --- meshing, in slices ------------------------------------------------
//
// Meshing the demo world takes seconds on a phone, and a phone that blocks its
// frame loop for seconds gets an "app isn't responding" dialog. The work is
// therefore a resumable state machine: the C frame loop calls demo_mesh_step()
// with a time budget, and each call completes as many sections as fit. The
// result is byte-identical to meshing everything at once, which is what
// tools/run_tests.sh checks.
//
// One column is meshed once, in three passes (opaque, cutout, translucent), and
// then its three batches are copied into their slots. Until 0.3.7 the batch loop
// was outside the column loop, so every column was meshed three times and thrown
// away twice: the loading screen said five seconds for work that takes one and a
// half.

// The budget is measured on this side, so one call cannot overrun it by much.
extern fn umbra_c_now_us() -> i64 = "umbra_c_now_us";

var dm_state: i64 = 0;   // 0 not begun, 1 running, 2 done
var dm_cols: i64[>..] = [];  // the columns this pass meshes
var dm_ci: i64 = 0;      // index into dm_cols
var dm_pass: i64 = 0;    // one of the column's three passes
var dm_sy: i64 = -4;     // section y within the column
var dm_units: i64 = 0;   // sections (and copies) completed
var dm_worst_unit_us: i64 = 0;
var dm_edit: bool = false;   // this pass is a re-mesh after an edit
var dm_remap: u32[>..] = [];

fn dm_slot_table() {
    sl_col = [];
    sl_batch = [];
    sl_v_off = [];
    sl_v_cap = [];
    sl_v_len = [];
    sl_i_off = [];
    sl_i_cap = [];
    sl_i_len = [];
    for b in 3 {
        for c in demo.len {
            sl_col.push(c);
            sl_batch.push(b);
            sl_v_off.push(-1);
            sl_v_cap.push(0);
            sl_v_len.push(0);
            sl_i_off.push(-1);
            sl_i_cap.push(0);
            sl_i_len.push(0);
        }
    }
}

fn dm_reset_pass(cols: i64[:], edit: bool) {
    dm_cols = [];
    for c in cols.len { dm_cols.push(cols[c]) }
    dm_edit = edit;
    dm_state = 1;
    dm_ci = 0;
    dm_pass = 0;
    dm_sy = -4;
    dm_units = 0;
    dm_worst_unit_us = 0;
    dm_dirty = [];
}

// The whole world, into empty arenas.
fn demo_mesh_begin() {
    world_verts = [];
    world_indices = [];
    dm_v_cursor = 0;
    dm_i_cursor = 0;
    dm_arena_reserve();
    dm_slot_table();
    var all: i64[>..] = [];
    for c in demo.len { all.push(c); }
    dm_reset_pass(all[..], false);
    dm_moved = true;
}

// Only these columns. The geometry of every other column stays where it is; that
// is the whole point of the slot table.
fn demo_mesh_begin_edit(cols: i64[:]) {
    if sl_col.len != 3 * demo.len { return; }   // no slots yet: nothing to patch
    dm_reset_pass(cols, true);
}

// Grows an arena by n elements in one go. The obvious `while n { push(...) }` pays a
// call and a capacity check per element, inside one uninterruptible unit: the device
// measured 40.1 ms for the unit that closes a column (run 43995987328), which is a
// stall a person sees on the loading screen. One slice append moves the elements in
// a single memcpy instead and lets the arena keep its own growth policy -- and the
// arena is sized once by dm_arena_reserve(), so placing a column does not grow it at
// all. (A slice append reallocates and copies everything, so growing per column cost
// the Windows runner 103 ms on the unit that closes a column.)
//
// The run to repeat lives in a module-level array: a literal built inside the function
// is a temporary, and Goose will not let a temporary be appended (§9.2) -- correctly,
// since the arena outlives the call.
// Where the free space in the pre-reserved arena starts; reset with the arenas.
var dm_v_cursor: i64 = 0;
var dm_i_cursor: i64 = 0;

var dm_zero_vertices: Vertex[>..] = [];
var dm_zero_indices: u32[>..] = [];

fn dm_grow_init() {
    if dm_zero_vertices.len == 0 {
        let zero = Vertex {
            x: 0.0, y: 0.0, z: 0.0, nx: 0.0, ny: 1.0, nz: 0.0,
            u: 0.0, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0,
        };
        for i in 64 { dm_zero_vertices.push(zero); }
    }
    if dm_zero_indices.len == 0 {
        for i in 64 { dm_zero_indices.push(0); }
    }
}

fn dm_grow_vertex_zeros(xs: Vertex[>..]&, n: i64) {
    if n <= 0 { return; }
    dm_grow_init();
    let zero = Vertex {
        x: 0.0, y: 0.0, z: 0.0, nx: 0.0, ny: 1.0, nz: 0.0,
        u: 0.0, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0,
    };
    let unit: Vertex[:] = dm_zero_vertices[0..64];
    // The tail is a run of one element and is grown once.
    var left = n / 64;
    while left > 0 {
        xs.append(unit);
        left -= 1;
    }
    var tail = n % 64;
    while tail > 0 {
        xs.push(zero);
        tail -= 1;
    }
}

fn dm_grow_u32_zeros(xs: u32[>..]&, n: i64) {
    if n <= 0 { return; }
    dm_grow_init();
    let unit: u32[:] = dm_zero_indices[0..64];
    var left = n / 64;
    while left > 0 {
        xs.append(unit);
        left -= 1;
    }
    var tail = n % 64;
    while tail > 0 {
        xs.push(0);
        tail -= 1;
    }
}

// Reserves the whole arena once, before the first column is placed, so that placing a
// column never grows it. The size is the geometry measured for the demo world with the
// slack each slot asks for (a quarter more vertices, a quarter more indices, plus a
// small fixed pad): 480k vertices, 780k indices. Growth is what costs: the slice append
// copies the arena every time it grows, so a build that grows it per column copies the
// whole world dozens of times -- which is exactly what the Windows runner measured at
// 103 ms for the unit that closes a column.
fn dm_arena_reserve() {
    // Sized to the geometry the host suite measures for this world (444 917 vertices,
    // 575 448 indices) plus the slack each slot asks for. The first attempt reserved
    // 480k/780k up front, which fixed Windows (103 ms unit -> 4.39) and cost the phone
    // twice over: the reservation itself became the longest unit, and the whole arena
    // -- slack included -- is what GL is asked to hold, so the upload doubled to 47 MB
    // for 26 MB of geometry (run 44001141590).
    const want_v: i64 = 480000;
    const want_i: i64 = 580000;
    if world_verts.len >= want_v && world_indices.len >= want_i { return; }
    dm_grow_init();
    let vunit: Vertex[:] = dm_zero_vertices[0..64];
    while world_verts.len + 64 <= want_v { world_verts.append(vunit); }
    while world_verts.len < want_v { world_verts.push(dm_zero_vertices[0]); }
    let iunit: u32[:] = dm_zero_indices[0..64];
    while world_indices.len + 64 <= want_i { world_indices.append(iunit); }
    while world_indices.len < want_i { world_indices.push(0); }
}

// Copies one batch of the column just meshed into its slot. Vertices land in the
// slot's reserved range, indices are made absolute, and the slot is marked dirty
// for the next upload.
fn demo_place_column(b: i64, c: i64) {
    let sid = b * demo.len + c;
    let start = batch_starts[b];
    let count = batch_counts[b];
    let ox = (demo[c].x as f32) * 16.0;
    let oz = (demo[c].z as f32) * 16.0;
    // Which mesh vertices this slice uses, and in what order.
    dm_remap = [];
    for k in mesh_verts.len { dm_remap.push(4294967295) }
    var need_v: i64 = 0;
    for k in count {
        let vi = mesh_indices[start + k];
        if dm_remap[vi as i64] == 4294967295 {
            dm_remap[vi as i64] = need_v as u32;
            need_v += 1;
        }
    }
    var reuse = false;
    if sl_v_off[sid] >= 0 && sl_v_cap[sid] >= need_v && sl_i_cap[sid] >= count {
        reuse = true;
    }
    if !reuse {
        // A new or grown slot. The arena was sized by dm_arena_reserve(), and the
        // cursor says where the free space starts: reserving without using the space
        // would waste it *and* grow the arena again, which is what run 44001141590
        // showed on the device (a 47 MB reserve with 1.3 M indices in the arena for
        // 556 k in use). If the reservation runs out, the arena grows as before.
        let vpad = need_v / 4 + 64;
        let ipad = count / 4 + 128;
        var vbase = dm_v_cursor;
        var ibase = dm_i_cursor;
        if vbase + need_v + vpad > world_verts.len || ibase + count + ipad > world_indices.len {
            vbase = world_verts.len;
            ibase = world_indices.len;
            dm_grow_vertex_zeros(world_verts, need_v + vpad);
            dm_grow_u32_zeros(world_indices, count + ipad);
        }
        dm_v_cursor = vbase + need_v + vpad;
        dm_i_cursor = ibase + count + ipad;
        sl_v_off[sid] = vbase;
        sl_v_cap[sid] = need_v + vpad;
        sl_i_off[sid] = ibase;
        sl_i_cap[sid] = count + ipad;
        dm_moved = true;
    }
    let vbase = sl_v_off[sid];
    // Vertices, in the order they first appear in this slice, moved to the column's
    // world position in x and z (y is the block's own height and is not offset).
    for k in mesh_verts.len {
        let local = dm_remap[k];
        if local == 4294967295 { continue; }
        let src = mesh_verts[k];
        world_verts[vbase + (local as i64)] = Vertex {
            x: src.x + ox, y: src.y, z: src.z + oz,
            nx: src.nx, ny: src.ny, nz: src.nz,
            u: src.u, v: src.v, r: src.r, g: src.g, b: src.b, ao: src.ao,
        };
    }
    // Indices, absolute.
    let ibase = sl_i_off[sid];
    for k in count {
        let local = dm_remap[mesh_indices[start + k] as i64] as i64;
        world_indices[ibase + k] = (vbase + local) as u32;
    }
    sl_i_len[sid] = count;
    sl_v_len[sid] = need_v;
    var known = false;
    for d in dm_dirty.len {
        if dm_dirty[d] == sid { known = true; }
    }
    if !known { dm_dirty.push(sid); }
}

// One section of one pass of one column, or the copy that closes a column.
fn demo_mesh_unit() {
    if dm_state != 1 { return; }
    if dm_ci >= dm_cols.len {
        dm_state = 2;
        return;
    }
    let c = dm_cols[dm_ci];
    // A fresh column starts with an empty mesh arena.
    if dm_pass == 0 && dm_sy == -4 { mesh_reset(); }
    if dm_sy == -4 { batch_starts[dm_pass] = mesh_indices.len; }
    let want = if dm_pass == 0 { RC_OPAQUE } else if dm_pass == 1 { RC_CUTOUT } else { RC_TRANSLUCENT };
    mesh_section_class(demo[c], dm_sy as i32, want);
    dm_sy += 1;
    if dm_sy <= 19 { return; }
    // That pass is finished.
    batch_counts[dm_pass] = mesh_indices.len - batch_starts[dm_pass];
    dm_sy = -4;
    dm_pass += 1;
    if dm_pass < 3 { return; }
    dm_pass = 0;
    for b in 3 { demo_place_column(b, c); }
    dm_ci += 1;
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

// Re-mesh only the columns an edit touched. The C side calls this instead of
// demo_mesh_begin, then steps the same stepper: the geometry of every other column
// stays in its slot, so the cost is this column's sections and nothing else.
export "umbra_demo_mesh_edit" fn demo_mesh_edit_export(cols: i64[:]) -> i64 {
    if dm_state == 1 { return 0; }   // one pass at a time
    demo_mesh_begin_edit(cols[..]);
    return if dm_state == 1 { 1 } else { 0 }
}

// What the last pass was: how many columns, whether it was an edit, and how much
// work it took. The numbers behind "an edit does not rebuild the world".
export fn umbra_mesh_columns() -> i64 { return dm_cols.len }
export fn umbra_mesh_is_edit() -> i64 { return if dm_edit { 1 } else { 0 } }
export fn umbra_mesh_worst_unit_ms() -> f32 { return (dm_worst_unit_us as f32) / 1000.0 }

// Progress in permille, for the loading screen.
// How many units this pass takes. Counted from the same structure the stepper
// walks, because the first version of this was wrong and showed the owner
// "LOADING WORLD 224%": every column's three passes of 24 sections, plus the one
// unit that closes the column. The headless check `units == total` compares the
// two numbers.
// Every section is a unit (3 passes of 24), and the last section of a column also
// does that column's three copies; one more unit ends the pass.
export fn umbra_demo_mesh_total_units() -> i64 {
    return dm_cols.len * (3 * 24) + 1;
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
// --- where the pixels and the models come from --------------------------
//
// Two sources, and which one is in use is a number the HUD and the log report:
//
//   * the placeholder set built here in Goose (core/textures.goose, D-039) -- twelve
//     tiles, so the renderer has *a* texture and the phone runs with no game data;
//   * the client jar's own textures and block models, when a jar is loaded. That is
//     what "drawn with the jar's textures" has to mean on the device: the same atlas
//     the CPU renderer in CI draws with, decoded from the jar's PNGs by core/jarpack,
//     and the mesher asking core/modelstore for each block's own model.
//
// A jar load either becomes the source for everything -- atlas, tile UVs, tints, the
// models the mesher uses -- or it fails and changes nothing. A half loaded jar is how
// a phone ends up drawing some blocks from the jar and some from nowhere.
var jar_ok: i64 = 0;
var jar_bytes: i64 = 0;
var jar_models: i64 = 0;
var jar_blockstates: i64 = 0;
var jar_textures: i64 = 0;

export "umbra_jar_load" fn jar_load_export(path: const u8[:]) -> i64 {
    jar_ok = 0;
    // The zip layer checks every extracted entry's CRC, and its table is built here:
    // without this the jar opens and every entry fails to extract, which reads as a
    // pack with no models in it.
    crc32_init();
    var data: u8[>..] = [];
    if !read_file(path, data) || data.len < 22 { return -1; }
    if !jp_open(data[..]) { return -2; }
    let models = jp_build_models();
    let states = jp_build_blockstates();
    let linked = ms_link_models();
    if models < 16 || states < 16 { return -3; }
    if linked <= 0 { return -3; }
    if !jp_build_atlas(16, 2) { return -4; }
    let layout = jp_atlas_layout();
    if layout.width <= 0 || layout.cells <= 0 { return -4; }
    mesh_set_layout(layout);
    for i in ms_path_count() {
        mesh_set_tile(i, jp_slot_of(i));
    }
    // Tints from the jar's own colormaps, the way the CPU renderer does it: plains is
    // temperature 0.8, humidity 0.4, and a colormap is indexed x = 1 - temperature,
    // y = 1 - humidity * temperature.
    var grass: f32[3] = [1.0, 1.0, 1.0];
    var foliage: f32[3] = [1.0, 1.0, 1.0];
    var water: f32[3] = [1.0, 1.0, 1.0];
    let cu = 1.0 - 0.8;
    let cv = 1.0 - 0.4 * 0.8;
    if jp_read_colormap("grass") {
        jp_colormap_color(cu, cv, grass);
        if jp_read_colormap("foliage") { jp_colormap_color(cu, cv, foliage); }
        if jp_read_colormap("water") { jp_colormap_color(cu, cv, water); }
    }
    mesh_set_tints(grass, foliage, water);
    mesh_use_store();
    jar_ok = 1;
    jar_bytes = data.len as i64;
    jar_models = models;
    jar_blockstates = states;
    jar_textures = jp_tex_used;
    return 1;
}

export "umbra_jar_active" fn jar_active() -> i64 { return jar_ok }
export "umbra_jar_bytes" fn jar_size() -> i64 { return jar_bytes }
export "umbra_jar_models" fn jar_model_count() -> i64 { return jar_models }
export "umbra_jar_blockstates" fn jar_state_count() -> i64 { return jar_blockstates }
export "umbra_jar_textures" fn jar_texture_count() -> i64 { return jar_textures }
export "umbra_jar_textures_missing" fn jar_texture_missing_count() -> i64 {
    if jar_ok == 0 { return 0; }
    return jp_texture_missing()
}

// --- the atlas, for the renderer ---------------------------------------
//
// The pixel buffer belongs to Goose; C uploads it to one GL texture and the
// vertices carry UVs inside it. Whichever source is loaded, the C side asks these
// functions and gets a consistent set of answers: size, layout, hash, and the texel
// the device self-test compares its GPU readback against.

fn atlas_live_pixels() -> const u8[:] {
    if jar_ok != 0 { return jp_atlas_pixels() }
    tex_build();
    return tex_atlas
}

fn atlas_live_layout() -> AtlasLayout {
    if jar_ok != 0 { return jp_atlas_layout() }
    return tex_layout_of()
}

export "umbra_atlas_build" fn atlas_build_export() { if jar_ok == 0 { tex_build() } }
export "umbra_atlas_pixels" fn atlas_pixels() -> const u8[:] { return atlas_live_pixels() }
export "umbra_atlas_size" fn atlas_size() -> i64 { return atlas_live_layout().width }
export "umbra_atlas_height" fn atlas_height() -> i64 { return atlas_live_layout().height }
export "umbra_atlas_hash" fn atlas_hash_export() -> u32 {
    if jar_ok != 0 { return jp_atlas_of_hash() }
    return tex_atlas_hash()
}
export "umbra_atlas_missing" fn atlas_missing() -> i64 {
    if jar_ok != 0 { return jp_texture_missing() }
    return tex_missing_count()
}
export "umbra_atlas_tiles" fn atlas_tiles() -> i64 {
    if jar_ok != 0 { return atlas_live_layout().cells }
    return TEX_COUNT
}
export "umbra_atlas_tile_u0" fn atlas_u0(slot: i64) -> f32 {
    return atlas_tile(atlas_live_layout(), slot).u0
}
export "umbra_atlas_tile_v0" fn atlas_v0(slot: i64) -> f32 {
    return atlas_tile(atlas_live_layout(), slot).v0
}
export "umbra_atlas_tile_u1" fn atlas_u1(slot: i64) -> f32 {
    return atlas_tile(atlas_live_layout(), slot).u1
}
export "umbra_atlas_tile_v1" fn atlas_v1(slot: i64) -> f32 {
    return atlas_tile(atlas_live_layout(), slot).v1
}
export "umbra_atlas_texel" fn atlas_texel(slot: i64, x: i64, y: i64) -> i64 {
    if jar_ok != 0 {
        return atlas_tile_texel(jp_atlas_pixels(), jp_atlas_layout(), slot, x, y)
    }
    return tex_texel(slot, x, y)
}
// A texture by its bare name ("oak_leaves", "stone"), as the self-test asks for it.
// In the jar the name is the last path component, so a suffix on "/<name>.png" finds
// it without the caller having to know whether the pack spells it minecraft:block/...
export "umbra_atlas_named" fn atlas_named(name: const u8[:]) -> i64 {
    if jar_ok == 0 { return tex_slot_for(name) }
    // The store's paths have no extension: "minecraft:block/oak_leaves". The name is
    // the last segment, compared whole, so "stone" does not match "smooth_stone".
    for i in ms_path_count() {
        let path = ms_path(i);
        var slash: i64 = -1;
        for k in path.len {
            if path[k] == 47 { slash = k; }
        }
        let tail = path[slash + 1 ..];
        if eq_bytes(tail, name) { return jp_slot_of(i) }
    }
    return -1
}

// --- the world, as a grid the player can walk on -----------------------
//
// The player needs one question answered per cell: how tall is the collision box
// in this block? A full block is 1.0, a bottom slab is 0.5 (from its model), and
// anything you can walk through -- air, water, plants, leaves are not solid here --
// is -1. This is the same knowledge the mesher used, asked the other way round.

fn demo_column_at(wx: i64, wz: i64) -> i64 {
    if wx < 0 || wz < 0 || wx >= 48 || wz >= 48 { return -1; }
    return (wz / 16) * 3 + (wx / 16);
}

fn demo_block_at(wx: i64, wy: i64, wz: i64) -> u32 {
    let ci = demo_column_at(wx, wz);
    if ci < 0 { return 0; }
    let c = demo[ci];
    return chunk_block(c, (wx % 16) as i32, wy as i32, (wz % 16) as i32);
}

export "umbra_block_top" fn block_top_export(wx: i64, wy: i64, wz: i64) -> f32 {
    let id = demo_block_at(wx, wy, wz);
    if id == 0 { return -1.0; }
    let rc = render_class(id);
    if rc == RC_CROSS { return -1.0; }
    if rc == RC_TRANSLUCENT { return -1.0; }   // water is swimmable, not walked on
    if model_bound && id == model_block {
        // A bound model's collision is its box: the demo slab is half a block.
        var lo: f32[3] = [0.0, 0.0, 0.0];
        var hi: f32[3] = [0.0, 0.0, 0.0];
        mdl_elem_box(0, lo, hi);
        return hi[1];
    }
    return 1.0;
}

// The floor height at a column of the world: the first y, from the top down, whose
// block can be stood on. The C spawn code asks for this instead of guessing.
export "umbra_world_spawn" fn world_spawn_export(wx: i64, wz: i64) -> f32 {
    var y: i64 = 120;
    while y > -64 {
        let t = block_top_export(wx, y, wz);
        if t > 0.0 { return (y as f32) + t; }
        y -= 1;
    }
    return 64.0;
}

export fn umbra_world_min_x() -> f32 { return 0.0 }
export fn umbra_world_max_x() -> f32 { return 48.0 }
export fn umbra_world_min_z() -> f32 { return 0.0 }
export fn umbra_world_max_z() -> f32 { return 48.0 }

// --- the player's hands --------------------------------------------------
//
// A short list of blocks to put down, and one action on the block under the crosshair.
// The ray, the world edit and the re-mesh all happen on this side: C owns the finger and
// the pixels, and asking it to also know what a block is would put the same rule in two
// places.
//
// A re-mesh after an edit is the same sliced state machine as the first one, so an edit
// cannot freeze the frame loop: the C loop asks for the next slice with a budget and
// draws between them. It re-meshes only the column the edit touched (and the neighbour
// across a chunk border), into that column's slot: the rest of the world keeps the
// geometry it already has.

var hb_ids: u32[>..] = [];
var hb_sel: i64 = 0;
var act_text: u8[>..] = [];

fn hotbar_init() {
    if hb_ids.len > 0 { return; }
    hb_ids.push(bs_intern("minecraft:grass_block", "snowy=false"));
    hb_ids.push(bs_intern("minecraft:dirt", ""));
    hb_ids.push(bs_intern("minecraft:stone", ""));
    hb_ids.push(bs_intern("minecraft:oak_log", "axis=y"));
    hb_ids.push(bs_intern("minecraft:oak_slab", "type=bottom"));
}

export fn umbra_hotbar_count() -> i64 { hotbar_init(); return hb_ids.len }
export fn umbra_hotbar_selected() -> i64 { return hb_sel }

// The block's name without its namespace: what the HUD has room for.
export "umbra_hotbar_name" fn hotbar_name(i: i64) -> const u8[:] {
    hotbar_init();
    if i < 0 || i >= hb_ids.len { return ""; }
    return bs_path(bs_name(hb_ids[i]))
}

export "umbra_hotbar_select" fn hotbar_select(i: i64) -> i64 {
    hotbar_init();
    if i >= 0 && i < hb_ids.len { hb_sel = i; }
    return hb_sel;
}

export "umbra_act_text" fn act_text_export() -> const u8[:] { return act_text }

fn act_say(what: const u8[:], name: const u8[:], x: i32, y: i32, z: i32) {
    act_text = [];
    act_text.append(what);
    act_text.append(" ");
    act_text.append(name);
    act_text.append(" at ");
    format(act_text, x, " ", y, " ", z);
}

// 0 breaks, 1 places. Returns 1 when the world changed, 0 when nothing was in reach,
// -1 when the edit was refused, -2 when a re-mesh is already running.
export "umbra_player_act" fn player_act(kind: i64, ex: f32, ey: f32, ez: f32,
                                       dx: f32, dy: f32, dz: f32, reach: f32) -> i64 {
    hotbar_init();
    if dm_state == 1 { act_text = []; act_text.append("busy: still meshing"); return -2; }
    let h = demo_raycast(ex, ey, ez, dx, dy, dz, reach);
    if kind == 0 {
        if !h.hit { act_text = []; act_text.append("nothing in reach"); return 0; }
        let name = bs_name(h.id);
        if !demo_set_block(h.x, h.y, h.z, 0) {
            act_text = []; act_text.append("that block is outside the world");
            return -1;
        }
        act_say("broke", bs_path(name), h.x, h.y, h.z);
        edit_cols = edit_columns_for(h.x, h.z);
        demo_mesh_begin_edit(edit_cols[..]);
        return 1;
    }
    // A place needs a face to place against.
    if !h.hit || h.face < 0 {
        act_text = []; act_text.append("nothing to build on");
        return 0;
    }
    var cell: i32[3] = [0, 0, 0];
    demo_face_neighbour(h, cell);
    if !demo_is_air(demo_block_at(cell[0], cell[1], cell[2])) {
        act_text = []; act_text.append("that space is taken");
        return -1;
    }
    let id = hb_ids[hb_sel];
    if !demo_set_block(cell[0], cell[1], cell[2], id) {
        act_text = []; act_text.append("outside the world");
        return -1;
    }
    act_say("placed", bs_path(bs_name(id)), cell[0], cell[1], cell[2]);
    edit_cols = edit_columns_for(cell[0], cell[2]);
    demo_mesh_begin_edit(edit_cols[..]);
    return 1;
}

// What a ray from the player's eye would hit, for the host checks and the HUD.
export "umbra_player_target" fn player_target(ex: f32, ey: f32, ez: f32, dx: f32, dy: f32,
                                              dz: f32, reach: f32) -> i64 {
    let h = demo_raycast(ex, ey, ez, dx, dy, dz, reach);
    if !h.hit { return -1; }
    return (h.y as i64) * 1000000 + (h.z as i64) * 1000 + (h.x as i64);
}

export "umbra_block_at" fn block_at_export(x: i32, y: i32, z: i32) -> const u8[:] {
    return bs_name(demo_block_at(x, y, z))
}

export "umbra_set_block" fn set_block_export(x: i32, y: i32, z: i32, name: const u8[:]) -> i64 {
    let id = bs_intern(name, "");
    return if demo_set_block(x, y, z, id) { 1 } else { 0 }
}

// --- the world's draw ranges -------------------------------------------
//
// One range per (batch, column) slot: where its indices start, how many there are,
// and which pass it belongs to. C draws each range with the offset in the index
// buffer, so an edit that rewrites one slot changes one range and no others. The
// ranges are ordered by pass, which is the order the world has to be drawn in:
// opaque, cutout, then the translucent water last.
export fn umbra_range_slots() -> i64 { return sl_col.len }
// Vertices the ranges actually draw: the arena also holds slack for the next edit.
export fn umbra_used_vertices() -> i64 {
    var total: i64 = 0;
    for i in sl_v_len.len { total += sl_v_len[i]; }
    return total
}
export fn umbra_range_batch(sid: i64) -> i64 {
    if sid < 0 || sid >= sl_batch.len { return 0; }
    return sl_batch[sid]
}
export fn umbra_range_vertex(sid: i64) -> i64 {
    if sid < 0 || sid >= sl_v_off.len { return 0; }
    return sl_v_off[sid]
}
export fn umbra_range_vertex_len(sid: i64) -> i64 {
    if sid < 0 || sid >= sl_v_len.len { return 0; }
    return sl_v_len[sid]
}
export fn umbra_range_index(sid: i64) -> i64 {
    if sid < 0 || sid >= sl_i_off.len { return 0; }
    return sl_i_off[sid]
}
export fn umbra_range_index_len(sid: i64) -> i64 {
    if sid < 0 || sid >= sl_i_len.len { return 0; }
    return sl_i_len[sid]
}

// Slots rewritten since the last upload. `umbra_mesh_moved` means the arena itself
// changed shape, so the whole buffers go up again; otherwise C uploads only these.
export fn umbra_dirty_count() -> i64 { return dm_dirty.len }
export fn umbra_dirty_slot(i: i64) -> i64 {
    if i < 0 || i >= dm_dirty.len { return -1; }
    return dm_dirty[i]
}
export fn umbra_mesh_moved() -> i64 { return if dm_moved { 1 } else { 0 } }
export "umbra_dirty_clear" fn dirty_clear() {
    dm_dirty = [];
    dm_moved = false;
}

// The columns an edit at a world position touches: its own, plus the neighbour
// across a chunk border, because a face on a border is decided by the block on the
// other side of it even though this column draws it.
fn edit_columns_for(x: i32, z: i32) -> i64[>..] {
    var cols: i64[>..] = [];
    var i = demo_column_of(x, z);
    if i >= 0 { cols.push(i); }
    if x % 16 == 0 { i = demo_column_of(x - 1, z); if i >= 0 { cols.push(i); } }
    if x % 16 == 15 { i = demo_column_of(x + 1, z); if i >= 0 { cols.push(i); } }
    if z % 16 == 0 { i = demo_column_of(x, z - 1); if i >= 0 { cols.push(i); } }
    if z % 16 == 15 { i = demo_column_of(x, z + 1); if i >= 0 { cols.push(i); } }
    return cols
}

export fn umbra_edit_column_count() -> i64 { return edit_cols.len }
export fn umbra_world_columns() -> i64 { return demo.len }

// What the player's hand does, without the ray: set one block, then start the re-mesh
// of the columns it touches. The host suite and the emulator harness drive edits
// through this, so the numbers they report are the numbers the phone gets.
export "umbra_edit_block" fn edit_block_export(x: i32, y: i32, z: i32, name: const u8[:]) -> i64 {
    let id = bs_intern(name, "");
    if !demo_set_block(x, y, z, id) { return 0; }
    edit_cols = edit_columns_for(x, z);
    demo_mesh_begin_edit(edit_cols[..]);
    return 1;
}

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

// --- the "get game files" flow ------------------------------------------
//
// A phone has no path to /data/local/tmp, so the app itself has to obtain the jar
// (D-043). The policy lives in core/gamefiles.goose: the pinned version, the URL
// shape, and the rule a file has to pass before it may become the world's
// textures. These exports are the four things the C screen needs to ask.
//
// The network and the file picker are the platform's: Java's HttpURLConnection for
// TLS (the NDK has no TLS client) and ACTION_OPEN_DOCUMENT for a file the owner
// already has. Both hand back bytes; nothing they say is trusted.

// Where the jar goes, and where a download lands before it is checked.
export "umbra_gf_jar_path" fn gf_jar_path(files_dir: const u8[:]) -> const u8[:] {
    gf_paths_jar = um_jar_path(files_dir);
    return gf_paths_jar[..]
}
export "umbra_gf_part_path" fn gf_part_path(files_dir: const u8[:]) -> const u8[:] {
    gf_paths_part = um_part_path(files_dir);
    return gf_paths_part[..]
}
var gf_paths_jar: u8[>..] = [];
var gf_paths_part: u8[>..] = [];

// Is a verified jar already in place? 1 when client.jar exists.
export "umbra_gf_jar_present" fn gf_jar_present(files_dir: const u8[:]) -> i64 {
    return if um_jar_present(files_dir) { 1 } else { 0 }
}

// The manifest URL, the pinned version, and the two numbers a download is held to.
export "umbra_gf_manifest_url" fn gf_manifest_url() -> const u8[:] { return UM_MANIFEST_URL }
export "umbra_gf_version" fn gf_version() -> const u8[:] { return UM_VERSION }
export "umbra_gf_pinned_bytes" fn gf_pinned_bytes() -> i64 { return UM_CLIENT_BYTES }
export "umbra_gf_pinned_sha1" fn gf_pinned_sha1() -> const u8[:] { return UM_CLIENT_SHA1 }

// The manifest names the pinned version's JSON: its URL and its sha1.
export "umbra_gf_manifest_lookup" fn gf_manifest_lookup(text: const u8[:]) -> i64 {
    return if um_manifest_lookup(text) { 1 } else { 0 }
}
export "umbra_gf_version_url" fn gf_version_url() -> const u8[:] { return um_version_url() }
export "umbra_gf_version_sha1" fn gf_version_sha1() -> const u8[:] { return um_version_sha1() }
export "umbra_gf_manifest_summary" fn gf_manifest_summary() -> const u8[:] {
    return um_manifest_summary()
}
// How many bytes of the version JSON the manifest's own sha1 covers: the platform
// fetches the text and hands it here; a file that is not the pinned version's JSON
// fails um_manifest_lookup or um_version_lookup, and the screen says so.
export "umbra_gf_version_lookup" fn gf_version_lookup(text: const u8[:]) -> i64 {
    return if um_version_lookup(text) { 1 } else { 0 }
}
export "umbra_gf_client_url" fn gf_client_url() -> const u8[:] { return um_client_url() }
export "umbra_gf_client_sha1" fn gf_client_sha1() -> const u8[:] { return um_client_sha1() }
export "umbra_gf_client_size" fn gf_client_size() -> i64 { return um_client_size() }

// The check: a jar, the pin's size, the pin's sha1, in that order. 1 passes; 0 does
// not, and umbra_gf_check_reason() says which of the three failed.
export "umbra_gf_check_file" fn gf_check_file(path: const u8[:]) -> i64 {
    let ok = um_check_file(path, UM_CLIENT_BYTES, UM_CLIENT_SHA1);
    um_remember_digest();
    return if ok { 1 } else { 0 }
}
export "umbra_gf_check_reason" fn gf_check_reason() -> const u8[:] { return um_check_reason() }
export "umbra_gf_digest" fn gf_digest() -> const u8[:] { return um_checksum_text() }

// The import path's verdict on a picked file: 1 accepted, 0 refused with a reason
// in umbra_gf_import_message().
export "umbra_gf_import_verdict" fn gf_import_verdict(path: const u8[:], got: i64) -> i64 {
    return um_import_verdict(path, got)
}
export "umbra_gf_import_message" fn gf_import_message() -> const u8[:] {
    return um_import_message()
}

// The screen's words. umbra_gf_state_set() returns the kind it was given, so a
// caller that passes a number it made up reads it back in the log.
export "umbra_gf_state_set" fn gf_state_set(kind: i64, now: i64, total: i64,
                                           extra: const u8[:]) -> i64 {
    return um_state_set(kind, now, total, extra)
}
export "umbra_gf_state_text" fn gf_state_text() -> const u8[:] { return um_state_text() }
export "umbra_gf_state_detail" fn gf_state_detail() -> const u8[:] { return um_state_detail() }
export fn umbra_gf_state_idle() -> i64 { return UM_ST_IDLE }
export fn umbra_gf_state_downloading() -> i64 { return UM_ST_DOWNLOADING }
export fn umbra_gf_state_verifying() -> i64 { return UM_ST_VERIFYING }
export fn umbra_gf_state_ready() -> i64 { return UM_ST_READY }
export fn umbra_gf_state_failed() -> i64 { return UM_ST_FAILED }
export fn umbra_gf_state_imported() -> i64 { return UM_ST_IMPORTED }
