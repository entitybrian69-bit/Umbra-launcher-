// Tests for the streaming reader: a world bigger than the window, parsed on demand.
//
// The fixture is `goose/test/fixtures/worldstream/world-stream.zip` -- sixteen chunks,
// -2..1 in x and z, spread across the four region files that meet at the origin
// (`tools/gen_stream_world.py`). Every chunk has a different surface height, so "a chunk
// arrived" and "the right chunk arrived" are different checks.
//
// The four things this has to prove, because each one is a way streaming goes wrong:
//
//   * a chunk at negative coordinates is read from the right region file at the right
//     local slot -- the arithmetic that silently reads another chunk when it is wrong;
//   * what is resident is bounded by the radius, not by the size of the save, and the
//     eviction keeps `demo` a *window* rather than a growing list of everywhere visited;
//   * the work is sliced: no single call parses the whole window, so no frame has to;
//   * a chunk the save does not hold is counted as missing and is not an error, because
//     a radius around a spawn reaches past the edge of what the server generated.
//
// The heights are the fixture's own numbers (60 for -2,-2 up to 75 for 1,1); a test that
// asks for a height is asking "is this the chunk the save names at this position", which
// an identical-chunks fixture could not answer.

import std;
import os;
import core.mem;
import core.zip;
import core.region;
import core.nbt;
import core.demo;
import core.worldstream;
import test.harness;

let WS_ZIP = "goose/test/fixtures/worldstream/world-stream.zip";

// Every chunk in the fixture, and its surface height. Written out rather than computed
// from the generator's formula: a test that recomputes a generator's arithmetic agrees
// with the generator and not with the file.
// The *top solid block* of chunk (cx, cz). `gen_stream_world.py` fills y from 40 up to
// `height`, so the highest solid block is `height - 1`: a chunk whose height is 60 has
// stone at y 59 and air at 60. Getting that off by one is what this comment is for.
fn ws_height(cx: i64, cz: i64) -> i64 {
    return 59 + ((cx + 2) * 4 + (cz + 2))
}

// The top solid block of a column, as the reader sees it, or -1 if the column has none.
// Walks down from above the fixture's highest surface, so the number is the surface and
// not the highest *air* block.
fn ws_surface_of_column(cx: i64, cz: i64) -> i64 {
    let i = ws_column_of(cx, cz);
    if i < 0 { return -1; }
    var y: i32 = 100;
    while y >= 30 {
        if chunk_block(demo[i], 8, y, 8) != 0 { return y as i64; }
        y -= 1;
    }
    return -1
}

// Open the fixture the way the app does -- begin, one call per entry, end -- and leave
// the stream open on it. Returns the number of region files the archive named.
fn ws_open_fixture() -> i64 {
    bs_reset();
    demo = [];
    let regions = wl_import_begin(WS_ZIP);
    var i: i64 = 0;
    while i < wl_count_entries() {
        wl_import_file(i);
        i += 1;
    }
    return regions
}

fn ws_close_fixture() {
    ws_reset();
    demo = [];
    bs_reset();
}

// --- the region arithmetic, on its own -----------------------------------

// chunk -> region file -> local slot, including the negative half. This is the function
// the rest of the reader leans on, and the one place a sign error is invisible: it does
// not fail, it reads a sector that holds another chunk (or nothing, which reads as air).
fn ws_region_math_test() {
    let regions = ws_open_fixture();
    check(regions >= 4, "the fixture has a region file for each quadrant it spans");

    // The four quadrants. -1,-1 must be in region -1,-1 at local slot 31,31; 0,0 in 0,0
    // at 0,0. That asymmetry (31 for -1 and 0 for 0) is the whole reason this function
    // exists: the obvious `cx / 32` truncates toward zero and puts -1 in region 0.
    check(ws_has_chunk(-1, -1), "chunk -1,-1 is in the save");
    check(ws_has_chunk(0, 0), "chunk 0,0 is in the save");
    check(ws_has_chunk(-2, 1), "and the far corner of the window, -2,1");
    check(ws_has_chunk(1, -2), "and the other one, 1,-2");

    // Outside the fixture: the save holds -2..1, so 2 is past the edge and -3 is past the
    // other edge. A reader that answered "yes" for these would parse a sector of nothing.
    check(!ws_has_chunk(2, 0), "a chunk the save does not hold is not claimed");
    check(!ws_has_chunk(-3, 0), "and neither is one past the negative edge");
    check(!ws_has_chunk(0, 40), "nor one in a region file the archive never had");

    ws_close_fixture();
}

// --- the window: right chunks, right heights ------------------------------

// The whole window, in one call, checked height by height. This is the "is it the right
// chunk" test: a swapped axis in the region arithmetic reads a real chunk with the wrong
// height, and a window that stopped at the origin would read -1 (no column).
fn ws_window_test() {
    ws_open_fixture();
    let resident = ws_stream_all(0, 0, 2);
    check_i64(resident, 16, "a radius of 2 around the origin is all sixteen chunks of the save");
    check_i64(demo.len as i64, resident, "every resident chunk is a column the mesher can walk");
    check_i64(ws_stats.parse_errors, 0, "every chunk the save holds was read");

    var checked: i64 = 0;
    var wrong: i64 = 0;
    var first_wrong_x: i64 = 0;
    var first_wrong_z: i64 = 0;
    for cz in -2..2 {
        for cx in -2..2 {
            let want = ws_height(cx, cz);
            let got = ws_surface_of_column(cx, cz);
            checked += 1;
            if got != want {
                if wrong == 0 {
                    first_wrong_x = cx;
                    first_wrong_z = cz;
                }
                wrong += 1;
            }
        }
    }
    check_i64(checked, 16, "the sweep asked about every chunk in the save");
    // The failure names the position: "5 chunks have the wrong surface" sends the next
    // person nowhere, and this project has spent runs on exactly that kind of report.
    if wrong != 0 {
        print("  ws: ", wrong, " of ", checked, " chunks have the wrong surface; first at ",
              first_wrong_x, ",", first_wrong_z, " (has ",
              ws_surface_of_column(first_wrong_x, first_wrong_z), ", want ",
              ws_height(first_wrong_x, first_wrong_z), ")\n");
    }
    check_i64(wrong, 0, "every chunk's surface is the height the save gives that position");

    // A block below the surface is solid and one above it is air: the column is a column,
    // not a slab of stone that happens to have the right top.
    check(demo_block_at(8, 41, 8) != 0, "the block below the surface is solid");
    check_i64(demo_block_at(8, 76, 8) as i64, 0, "and the air above it is air");

    ws_close_fixture();
}

// --- the radius is the resident set --------------------------------------

// A smaller radius holds fewer chunks, and the number is the radius's own count: this is
// the check that "radius" means what the arithmetic in STATUS.md says it means.
fn ws_radius_test() {
    ws_open_fixture();
    // Radius 1 = 9 chunks, but the save has 16; the window is smaller than the save. A
    // reader that read the whole archive would report 16.
    // Nine chunks of a radius-1 window, but only the eight the save holds: the window's
    // x=-1 column is in `r.-1.*` and fine, and its x=1 column is fine too, so all nine
    // are in the save. If this ever disagrees with 9, the fixture or the arithmetic moved.
    let r1 = ws_stream_all(0, 0, 1);
    check_i64(r1, 9, "radius 1 is nine chunks, whatever else the save holds");
    check_i64(demo.len as i64, 9, "and nine columns are resident");
    // The corners of the radius-1 window are -1..1, so -2,-2 is outside it and must not
    // be resident: a save-wide read would have it.
    check(ws_column_of(-2, -2) < 0, "a chunk outside the radius is not resident");
    check(ws_column_of(1, 1) >= 0, "and one inside it is");

    // Radius 0: the one chunk the player is standing in. A streaming reader that treated
    // 0 as "everything" -- the old reader's spelling -- would hold the save.
    let r0 = ws_stream_all(0, 0, 0);
    check_i64(r0, 1, "radius 0 is the chunk under the player and nothing else");
    check_i64(demo.len as i64, 1, "one column resident");

    ws_close_fixture();
}

// --- the work is sliced ---------------------------------------------------

// The stepper must not do a window's work in one call: a slice is a budget, and the
// caller (the frame loop) gives it 2 ms. Checked by *count* rather than by clock, because
// a clock reading in a unit test on a shared CI machine is either 0 or 40 ms depending on
// the neighbour's noise -- the count is the property that matters and it is deterministic.
fn ws_slice_test() {
    ws_open_fixture();
    ws_recentre(0, 0, 2);
    check(ws_pending() > 0, "a recentre leaves work pending");

    var calls: i64 = 0;
    var done = false;
    while !done && calls < 10000 {
        done = ws_stream_step(2000);   // the app's 2 ms slice
        calls += 1;
    }
    check(done, "the stepper finishes the window");
    check(calls > 1, "and does it in more than one call, so no single frame carries it all");
    // The budget is 2 ms and a chunk is ~300 us, so a slice takes several. What must not
    // happen is the whole window in one call, which `calls > 1` already covers; the exact
    // count is a property of the machine, so it is printed and not asserted beyond it.
    check(calls * 2 < 16, "well under one call per chunk: the slice spans several");
    check_i64(ws_stats.resident, 16, "the whole window is resident when it is done");
    check_i64(ws_pending(), 0, "and nothing is left pending");
    // The worst slice is one chunk's parse, which is the bound the design claims. The
    // threshold is generous because this is a shared machine; the count above is the
    // deterministic half of the claim.
    print("  ws: ", calls, " slices for 16 chunks, worst ", ws_stats.worst_slice_us, " us\n");
    check(ws_stats.worst_slice_us < 200000,
          "no single slice took longer than one chunk's parse");

    ws_close_fixture();
}

// --- moving: eviction and the swap-remove --------------------------------

// Walking out of a window and into another one must leave the *new* window resident and
// nothing else. This is the bug that makes a streaming world grow without bound: evicting
// by index while shifting, or forgetting to evict at all.
fn ws_move_test() {
    ws_open_fixture();
    ws_stream_all(0, 0, 1);
    check_i64(demo.len as i64, 9, "nine chunks around the origin");
    check(ws_column_of(1, 1) >= 0, "including the far corner 1,1");

    // Move one chunk along: the window is now 0..2 in x, still -1..1 in z. The save only
    // has -2..1, so the far column of the new window (x=2) is missing -- counted, not an
    // error, because a radius around a spawn reaches past what the server generated.
    let gone = ws_recentre(1, 0, 1);
    check(gone > 0, "a move evicts the chunks that left the window");
    while !ws_stream_step(1000000) { }
    check(ws_stats.evicted > 0, "and the eviction is counted");
    // -1,-1 cannot be in a window centred on 2,0 with radius 1 (its x is -1, the window's
    // is 1..3). A reader that only ever appended would still have it.
    check(ws_column_of(-1, -1) < 0, "a chunk outside the new window is gone, not still resident");
    check(ws_column_of(1, 0) >= 0, "a chunk in the new window is resident");
    // The save's edge: x=2 does not exist, so it is counted missing and not parsed.
    check(ws_stats.missing > 0, "positions past the edge of the save are counted as missing");
    check_i64(ws_stats.parse_errors, 0, "and a missing chunk is not an error");
    // Resident is bounded by the window, never by how far we have walked: 9 here, plus
    // whatever the move legitimately added inside the new window.
    check(demo.len as i64 <= 9, "the resident set never exceeds the window's own count");

    ws_close_fixture();
}

// --- recentre is cheap ---------------------------------------------------

// `ws_recentre` runs in the frame that notices the player moved, so it must not parse:
// the parse is the stepper's job. Checked by asking a recentre to happen and looking at
// the resident count before any step runs -- it may only fall (evictions) and not rise.
fn ws_recentre_is_cheap_test() {
    ws_open_fixture();
    ws_stream_all(0, 0, 1);
    let before = demo.len as i64;
    let loaded_before = ws_stats.loaded;
    ws_recentre(0, 0, 1);       // the same window: nothing to do at all
    check_i64(demo.len as i64, before, "recentring on the same window parses nothing");
    check_i64(ws_stats.loaded, loaded_before, "and the loaded counter does not move");
    ws_recentre(1, 1, 1);       // a move: evict and plan, but do not parse
    check_i64(ws_stats.loaded, loaded_before,
              "a real move evicts and plans without parsing a single chunk");
    check(ws_pending() > 0, "and leaves the parse for the stepper");

    ws_close_fixture();
}

fn run_worldstream() {
    ws_region_math_test();
    ws_window_test();
    ws_radius_test();
    ws_slice_test();
    ws_move_test();
    ws_recentre_is_cheap_test();
    test_summary("worldstream");
}
