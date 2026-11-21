// Umbra core: streaming a world too big to hold.
//
// Until this file existed the reader had one answer to "how much of the save is open":
// a window of `WL_WINDOW = 2` chunks around the origin, and everything else thrown away
// before the mesher ever saw it. On the sample save that is 25 chunks of 1 225 -- the
// server generated a 160 by 160 block area around the spawn and the app drew a 80 by 80
// piece of it, `left out 1200`. The brief's first step is to walk in a bigger world, and
// the arithmetic says a bigger window cannot be held statically:
//
//   radius 16 is 1 089 chunks, 25.4 M vertices, 1.22 GB of 48-byte vertices, plus 328 MB
//   of decompressed block data. Radius 8 is still 324 MB of geometry and 87 MB of blocks.
//
// Neither is a phone. So the world is not held: the *save* is held, and the chunks the
// player is near are parsed from it on demand. What is resident is bounded by a radius,
// and what is in memory is the region files' bytes plus the columns inside that radius --
// which is the same budget the old window spent, spent on the chunks that are actually
// being drawn instead of on the ones that happen to be first in a directory listing.
//
// Three things make this safe, and each one is the reason for a decision below:
//
//   * **Parsing is sliced, not synchronous.** A column is 24 sections of 12 544 bytes --
//     301 KB -- and decoding one chunk is a zlib inflate plus a bit-unpack of 98 304
//     blocks. Doing that inside a frame is a stall. So the work is a stepper: one call
//     does as much as the budget allows and returns, exactly as the mesher's does.
//
//   * **`demo` is the resident set, and being in it means being drawable.** The mesher,
//     the player's ray, the edit path and the camera all walk `demo`, and changing them
//     all to go through a cache would be four chances to introduce a bug in code that is
//     known to work. So the streaming layer *maintains* `demo`: a chunk entering the
//     radius is parsed and appended, a chunk leaving it is removed. Nothing downstream
//     learns a new word.
//
//   * **A removed column's slot is reused.** The mesh side keeps a (batch, column) slot
//     per column and indexes them by `batch * demo.len + col`, so removing a column from
//     the middle would re-index every slot after it (and `demo_place_column` re-uses a
//     slot only if its capacity fits). Columns are therefore swapped out by *moving the
//     last column into the removed one's place*, which only changes the indices of one
//     slot group -- and the caller re-meshes the world, which is the one operation this
//     project already slices until it fits a frame.
//
// The bug this design exists to prevent is worth stating: a chunk that is not in `demo`
// is not "not yet meshed", it is *air*. The mesher culls a face against its neighbour,
// and `demo_block_at` answers 0 for a column it does not have. A window that ends inside
// the draw distance therefore shows a wall of holes at its edge and water you can see
// through. The radius the player sees and the radius `demo` holds must be the same
// number, which is why there is one setting and not two.

import std;
import os;
import core.mem;
import core.zip;
import core.nbt;
import core.region;
import core.demo;

// The clock the frame loop budgets against.
//
// Declared under its own Goose name with its own C symbol (`umbra_stream_now_us`, an alias
// of `umbra_c_now_us` in `platform/shared/umbra_glue.c`) rather than reusing either
// `main.goose`'s declaration or its symbol: two `extern fn`s with the same return type and
// the same C symbol are an "ambiguous overload" at every call site that can see both, and
// this module is compiled both on its own (the world reader) and inside the app (where
// `main.goose` is also present). The alias is two lines in C and removes the ambiguity
// from both builds.
extern fn umbra_stream_now_us() -> i64 = "umbra_stream_now_us";

// How many chunks a radius holds: the square, because a window is a square. Named so the
// log can quote it and the tests can hold it against the arithmetic in D-048.
fn ws_chunks_for(radius: i64) -> i64 {
    if radius < 0 { return 0; }
    let across = radius * 2 + 1;
    return across * across
}

// The region files, kept as a range of the archive's own bytes. Not a copy: `archive` is
// the archive's decompressed entries, and a read-only view of the bytes is all the chunk
// decoder needs. A save's region file is 4 to 8 MB and there are four of them in the
// sample, so this is ~30 MB rather than ~40 MB of block data.
struct WsRegion {
    rx: i64,
    rz: i64,
    bytes: Sref,       // the region file, inside the archive arena
}

// The column `ws_load_chunk` parses into, pushed by its caller. See the note there for
// why the push is not in the same function as the parse.
var ws_col: ChunkColumn = ChunkColumn { x: 0, z: 0, present: false, data_version: 0,
                                       status: Sref { off: -1, len: 0 },
                                       sections: [Section { y: 0, present: false, bits: 0,
                                                            palette_len: 0, palette: [0; 1024],
                                                            blocks: [0; 4096], biomes_len: 0,
                                                            biomes: [0; 64],
                                                            sky_light: [0; 4096],
                                                            block_light: [0; 4096],
                                                            light_read: false }; 24],
                                       section_lo: 24, section_hi: -1 };

var ws_regions: WsRegion[>..] = [];
var ws_archive: u8[>..] = [];
var ws_open: bool = false;

// What the stream has done, and what it is doing. Every number here is reported by the
// log and read by the tests, because "the world is bigger now" is a claim that needs a
// count behind it -- the whole point of the step is a number that went up.
struct WsStats {
    resident: i64,      // columns in `demo` right now
    loaded: i64,        // columns parsed since the world opened
    evicted: i64,       // columns dropped since the world opened
    parse_errors: i64,  // chunks the decoder refused
    missing: i64,       // positions the radius asked for that the save does not have
    seen: i64,          // positions the last scan visited (the ring, not the disc)
    centre_x: i64,      // the chunk the resident set is centred on
    centre_z: i64,
    radius: i64,        // the radius it was centred with
    peak_resident: i64,
    slice_calls: i64,   // how many stepper calls it took
    worst_slice_us: i64,
}
var ws_stats = WsStats {
    resident: 0, loaded: 0, evicted: 0, parse_errors: 0, missing: 0, seen: 0,
    centre_x: 0, centre_z: 0, radius: 0, peak_resident: 0, slice_calls: 0,
    worst_slice_us: 0,
};

// The scan in progress. It is a list of chunk positions to consider, built once per move
// and consumed a slice at a time: the ring around the centre, minus the ones already
// resident, which is the set that has to be parsed. Building the list is cheap arithmetic
// (289 pairs at radius 8) and visiting it is the expensive half, so the list is what the
// budget slices through.
var ws_todo_x: i64[>..] = [];
var ws_todo_z: i64[>..] = [];
var ws_todo_at: i64 = 0;
var ws_scan_active: bool = false;

fn ws_reset() {
    ws_regions = [];
    ws_archive = [];
    ws_open = false;
    ws_extent_reset();
    ws_todo_x = [];
    ws_todo_z = [];
    ws_todo_at = 0;
    ws_scan_active = false;
    ws_stats = WsStats {
        resident: 0, loaded: 0, evicted: 0, parse_errors: 0, missing: 0, seen: 0,
        centre_x: 0, centre_z: 0, radius: 0, peak_resident: 0, slice_calls: 0,
        worst_slice_us: 0,
    };
}

// The import hands each region file over as it reads it. The bytes are a view into
// `archive`, whose length only ever grows while the archive is open, and `Sref` is an
// offset and a length rather than a pointer -- so appending to `archive` later cannot
// invalidate a region taken earlier. That is the property `core.mem` exists for, and it
// is why a region is a `Sref` and not a slice.
fn ws_add_region(rx: i64, rz: i64, archive: u8[:], bytes: Sref) {
    if !ws_open {
        // The first region of an import: this is where the archive is adopted. Kept as a
        // separate step rather than a parameter on every call, because the archive is the
        // one thing all the regions share and copying it per region would be the save
        // four times over.
        ws_archive = [];
        for b in archive { ws_archive.push(b); }
        ws_open = true;
    }
    ws_regions.push(WsRegion { rx: rx, rz: rz, bytes: bytes });
}

// Note a region file the import has just decompressed, and keep its bytes.
//
// The import's `region` buffer is scratch -- the next entry's extraction overwrites it --
// so the bytes are copied into the stream's own arena here, once, and everything after
// this reads that copy. A region file is 4 to 8 MB and the sample save has four, which is
// ~30 MB: the same order as the window of block data the old reader held, and it buys a
// world that keeps going instead of one that stops 80 blocks from the spawn.
fn ws_note_region(rx: i64, rz: i64, bytes: const u8[:]) {
    if !ws_open {
        ws_archive = [];
        ws_open = true;
    }
    let off = ws_archive.len;
    for b in bytes { ws_archive.push(b); }
    let view = sref_of(ws_archive[..], off, bytes.len as i64);
    ws_regions.push(WsRegion { rx: rx, rz: rz, bytes: view });
    ws_extent_note(rx, rz);
}

// Which region file holds chunk (cx, cz), or -1. A region file is 32x32 chunks and its
// origin is floor-divisible, so -1 is in region -1 and -33 is in region -2.
fn ws_region_index(cx: i64, cz: i64) -> i64 {
    let rx = if cx < 0 { (cx + 1) / 32 - 1 } else { cx / 32 };
    let rz = if cz < 0 { (cz + 1) / 32 - 1 } else { cz / 32 };
    for i in ws_regions.len {
        if ws_regions[i].rx == rx && ws_regions[i].rz == rz { return i; }
    }
    return -1
}

// Is this chunk position one the save actually holds? Not whether it has blocks -- an
// empty chunk is a chunk -- but whether there is a region file for it and a location in
// that file's header. Used to skip positions the radius asks for that were never
// generated, and to count them, because a resident set that is silently smaller than its
// radius is the bug this whole file exists to avoid.
fn ws_has_chunk(cx: i64, cz: i64) -> bool {
    let r = ws_region_index(cx, cz);
    if r < 0 { return false; }
    let bytes = sref_bytes(ws_archive[..], ws_regions[r].bytes);
    let rx = if cx < 0 { (cx + 1) / 32 - 1 } else { cx / 32 };
    let rz = if cz < 0 { (cz + 1) / 32 - 1 } else { cz / 32 };
    let h = region_location(bytes, (cx - rx * 32) as i32, (cz - rz * 32) as i32);
    return h.offset != 0 && h.sectors != 0
}

// One chunk, parsed into the scratch column. Returns 1 when the column arrived, 0 when
// the save has nothing there, and -1 when it has something that could not be read -- three
// answers because "absent" and "corrupt" are different worlds and the counters say so.
//
// It fills `ws_col` and does not push into `demo`; the caller does. That is not a
// correction for anything in the compiler -- it was written that way while chasing a
// bug that turned out to be `ws_column_of` below -- but it is the shape worth keeping:
// the parse and the place it lands are two steps, and a chunk that fails to parse cannot
// leave half a column in the world.
fn ws_load_chunk(cx: i64, cz: i64) -> i64 {
    let r = ws_region_index(cx, cz);
    if r < 0 { return 0; }
    let bytes = sref_bytes(ws_archive[..], ws_regions[r].bytes);
    let rx = ws_regions[r].rx;
    let rz = ws_regions[r].rz;
    let lx = (cx - rx * 32) as i32;
    let lz = (cz - rz * 32) as i32;
    let h = region_location(bytes, lx, lz);
    if h.offset == 0 || h.sectors == 0 { return 0; }
    var nbt: u8[>..] = [];
    let got, err = region_chunk_nbt(bytes, lx, lz, nbt);
    if !got { return -1; }
    nbt_reset();
    var nerr: u8[>..] = [];
    let root = nbt_parse(nbt[..], nerr);
    if root < 0 { return -1; }
    ws_col = column_new();
    column_from_nbt(root, ws_col);
    // The position the save names wins over the one in the header, so a chunk in the
    // wrong place is drawn from the header's coordinates -- the header is where the
    // region file says it put it.
    ws_col.x = cx as i32;
    ws_col.z = cz as i32;
    return 1
}

// Take a column out of `demo`, and put it back where it can be found.
//
// The last column is moved into the hole rather than every later column shuffled down:
// `demo_column_of` is a linear scan and does not care what order the array is in, and the
// mesh slot index changes for exactly one column instead of all of them. What the caller
// must then do is re-mesh -- see the note at the top of the file.
fn ws_evict_at(i: i64) -> bool {
    if i < 0 || i >= demo.len { return false; }
    let last = demo.len - 1;
    if i != last { demo[i] = demo[last]; }
    demo.pop();
    ws_stats.resident = demo.len as i64;
    ws_stats.evicted += 1;
    return true
}

// Drop the columns outside `radius` of (cx, cz). Returns how many went.
fn ws_evict_outside(cx: i64, cz: i64, radius: i64) -> i64 {
    var gone: i64 = 0;
    var i: i64 = 0;
    while i < demo.len {
        let dx = (demo[i].x as i64) - cx;
        let dz = (demo[i].z as i64) - cz;
        if dx < 0 - radius || dx > radius || dz < 0 - radius || dz > radius {
            if ws_evict_at(i) { gone += 1; }
            // Do not advance: the column that was last is now at `i` and has not been
            // looked at yet. Advancing here is the classic skip-every-other bug.
            continue;
        }
        i += 1;
    }
    return gone
}

// The ring of positions that are not resident yet, in the order they will be parsed:
// nearest to the centre first, so the world appears from the player outward rather than
// in whatever order a directory listing produced. A ring, not a disc, because the
// columns already inside the radius are already in `demo`.
fn ws_plan_ring(cx: i64, cz: i64, radius: i64) {
    ws_todo_x = [];
    ws_todo_z = [];
    ws_todo_at = 0;
    // Distance 0 first, then outward. For each distance, the four sides of the square.
    var d: i64 = 0;
    while d <= radius {
        if d == 0 {
            ws_todo_x.push(cx);
            ws_todo_z.push(cz);
        } else {
            var k = 0 - d;
            while k <= d {
                ws_todo_x.push(cx + k); ws_todo_z.push(cz - d);
                ws_todo_x.push(cx + k); ws_todo_z.push(cz + d);
                k += 1;
            }
            // The two sides, without the corners the rows above already took.
            k = 0 - d + 1;
            while k < d {
                ws_todo_x.push(cx - d); ws_todo_z.push(cz + k);
                ws_todo_x.push(cx + d); ws_todo_z.push(cz + k);
                k += 1;
            }
        }
        d += 1;
    }
    ws_scan_active = true;
    ws_stats.seen = ws_todo_x.len;
}

// Is the resident set already the window around (cx, cz)? The cheap question the frame
// loop asks every frame, before it decides to do any work at all.
fn ws_is_centred(cx: i64, cz: i64, radius: i64) -> bool {
    if !ws_open { return false; }
    if ws_scan_active { return false; }
    if ws_stats.centre_x != cx || ws_stats.centre_z != cz || ws_stats.radius != radius {
        return false;
    }
    return true
}

// Move the resident set to (cx, cz): evict what is outside, plan the ring of what is
// missing. Cheap -- no chunk is parsed here -- so it is safe to call from a frame that
// has no budget left, and the stepper does the work over the following frames.
//
// Evicting before planning is what keeps the *peak* bounded by the radius: plan then
// evict would briefly hold both windows.
fn ws_recentre(cx: i64, cz: i64, radius: i64) -> i64 {
    if !ws_open { return 0; }
    ws_stats.centre_x = cx;
    ws_stats.centre_z = cz;
    ws_stats.radius = radius;
    let gone = ws_evict_outside(cx, cz, radius);
    ws_plan_ring(cx, cz, radius);
    return gone
}

// One slice of the work: parse positions from the ring until the budget is spent. Returns
// true when the ring is empty, which is the same contract as `demo_mesh_step`.
//
// The budget is checked *before* each chunk, not after, because one chunk is the
// indivisible unit here: a slice that has spent its budget still parses the next chunk if
// the check came first, and that is the stall this function exists to avoid. The worst
// slice is therefore one chunk, which is what the log reports.
fn ws_stream_step(budget_us: i64) -> bool {
    if !ws_open { return true; }
    if !ws_scan_active { return true; }
    let start = umbra_stream_now_us();
    ws_stats.slice_calls += 1;
    while ws_todo_at < ws_todo_x.len {
        if umbra_stream_now_us() - start >= budget_us { break; }
        let t0 = umbra_stream_now_us();
        let cx = ws_todo_x[ws_todo_at];
        let cz = ws_todo_z[ws_todo_at];
        ws_todo_at += 1;
        // Resident already? A column can be in `demo` and in the ring: the ring is the
        // whole window, and a recentre that did not move far keeps most of it.
        let have = ws_column_of(cx, cz);
        if have < 0 {
            let got = ws_load_chunk(cx, cz);
            if got < 0 {
                ws_stats.parse_errors += 1;
            } else if got == 0 {
                ws_stats.missing += 1;
            } else {
                demo.push(ws_col);
                ws_stats.loaded += 1;
                // Derived, not incremented. The two are the same number right up until a
                // chunk is evicted and re-added in one window, and then only one of them
                // is true: the counter said 16 chunks were resident while `demo` held
                // them all and the log said 0. `demo.len` is the number the mesher walks,
                // so it is the number the report has to quote.
                ws_stats.resident = demo.len as i64;
                if ws_stats.resident > ws_stats.peak_resident {
                    ws_stats.peak_resident = ws_stats.resident;
                }
            }
        }
        let took = umbra_stream_now_us() - t0;
        if took > ws_stats.worst_slice_us { ws_stats.worst_slice_us = took; }
    }
    if ws_todo_at >= ws_todo_x.len {
        ws_scan_active = false;
        ws_todo_x = [];
        ws_todo_z = [];
        ws_todo_at = 0;
        return true;
    }
    return false
}

// The whole window in one call, for tools and tests. Returns the columns resident.
fn ws_stream_all(cx: i64, cz: i64, radius: i64) -> i64 {
    ws_recentre(cx, cz, radius);
    while !ws_stream_step(1000000) { }
    return ws_stats.resident
}

// Which column is resident at chunk (cx, cz), or -1.
//
// Chunk space, not block space. `demo_column_of` takes *block* coordinates and floors
// them by 16 -- it is the function the player's ray and the edit path use, and it is
// right for them. Passing a chunk coordinate to it asks about the chunk *containing* that
// block position, so chunk 1 becomes block 0 and matches the column at chunk 0: the
// reader then believes the chunk it is missing is already resident, skips it, and the
// world opens with holes exactly where the window's positive half should be. That was a
// day of debugging, and the tell was a window that held 10 of its 16 chunks with every
// missing one at a positive coordinate.
fn ws_column_of(cx: i64, cz: i64) -> i64 {
    for i in demo.len {
        if (demo[i].x as i64) == cx && (demo[i].z as i64) == cz { return i }
    }
    return -1
}

// The import has just put its window into `demo` itself, without going through the
// stepper, so the counter the stream reports has to be told. Without this the log says
// "0 columns resident" for a world that is holding sixteen of them -- the number was
// right and the sentence was wrong, which is the kind of report that sends the next
// person looking in the wrong place.
// Is this import streamed? Set by the caller before `wl_import_begin`, because it is a
// decision about who reads the world -- the import reading a window it will then throw
// away is the thing this whole file exists to stop -- and it has to be known before the
// first chunk is met.
//
// Off by default: a tool that reads a save and prints what is in it (`worldload`, the
// comparison against the server) wants every chunk in the window parsed in one call, and
// asking it to drive a stepper would be a second implementation of the same loop.
var ws_stream_mode_on: bool = false;
fn ws_set_stream_mode(on: bool) { ws_stream_mode_on = on; }
fn ws_stream_mode_on_now() -> bool { return ws_stream_mode_on }

// How many non-air blocks the resident window holds. Counted from the columns that are
// there rather than remembered from a parse, so it is the number the mesher is looking at.
fn ws_blocks_in_window() -> i64 {
    var n: i64 = 0;
    for i in demo.len {
        var y: i32 = -64;
        while y < 320 {
            for z in 16 {
                for x in 16 {
                    let id = chunk_block(demo[i], x as i32, y, z as i32);
                    if id != 0 && !demo_is_air(id) { n += 1; }
                }
            }
            y += 1;
        }
    }
    return n
}

fn ws_resident_sync() {
    ws_stats.resident = demo.len as i64;
    if ws_stats.resident > ws_stats.peak_resident { ws_stats.peak_resident = ws_stats.resident; }
}

fn ws_regions_count() -> i64 { return ws_regions.len }

// --- the save's own extent, and why it is not the loaded window's ----------
//
// The window is a radius around the player: it moves. The *save* does not. These four
// numbers are the block bounds of every region file the archive held, computed once when
// the regions are noted, so a caller can ask "is this cell inside the world the owner
// imported" without confusing it with "is this cell in the part I happen to have parsed
// right now".
//
// The bug that made the distinction necessary: step 3 put the body's edge wall at the
// *window's* bounds, and the window is centred on the body, so the body could never walk
// out of the window it was standing in. Streaming then never re-centred -- it re-centres
// when the body crosses a chunk line -- and the device run failed with a body at the same
// coordinate for ten seconds. A wall at the edge of the save is the thing step 3 was
// asked for; a wall at the edge of the window is a cage.
var ws_have_extent: bool = false;
var ws_ext_min_cx: i64 = 0;
var ws_ext_max_cx: i64 = 0;
var ws_ext_min_cz: i64 = 0;
var ws_ext_max_cz: i64 = 0;

fn ws_extent_reset() {
    ws_have_extent = false;
    ws_ext_min_cx = 0; ws_ext_max_cx = 0;
    ws_ext_min_cz = 0; ws_ext_max_cz = 0;
}

fn ws_extent_note(rx: i64, rz: i64) {
    // A region is 32x32 chunks, so region rx covers chunks rx*32 .. rx*32+31.
    let lo_x = rx * 32;
    let hi_x = rx * 32 + 31;
    let lo_z = rz * 32;
    let hi_z = rz * 32 + 31;
    if !ws_have_extent {
        ws_ext_min_cx = lo_x; ws_ext_max_cx = hi_x;
        ws_ext_min_cz = lo_z; ws_ext_max_cz = hi_z;
        ws_have_extent = true;
        return;
    }
    if lo_x < ws_ext_min_cx { ws_ext_min_cx = lo_x; }
    if hi_x > ws_ext_max_cx { ws_ext_max_cx = hi_x; }
    if lo_z < ws_ext_min_cz { ws_ext_min_cz = lo_z; }
    if hi_z > ws_ext_max_cz { ws_ext_max_cz = hi_z; }
}

fn ws_extent_known() -> bool { return ws_have_extent }
fn ws_extent_min_block_x() -> f32 { return (ws_ext_min_cx as f32) * 16.0; }
fn ws_extent_max_block_x() -> f32 { return ((ws_ext_max_cx as f32) + 1.0) * 16.0; }
fn ws_extent_min_block_z() -> f32 { return (ws_ext_min_cz as f32) * 16.0; }
fn ws_extent_max_block_z() -> f32 { return ((ws_ext_max_cz as f32) + 1.0) * 16.0; }
fn ws_bytes_held() -> i64 { return ws_archive.len }
fn ws_pending() -> i64 {
    if !ws_scan_active { return 0; }
    return ws_todo_x.len - ws_todo_at
}
fn ws_is_open() -> i64 { return if ws_open { 1 } else { 0 } }
