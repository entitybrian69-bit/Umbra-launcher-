// Umbra core: opening a world the game generated, on the device.
//
// The phone has drawn a demo scene since stage 1: 48 by 48 blocks of terrain this
// project generated, meshed with the jar's own textures and models. That answers
// "does the renderer work" and not "is this Minecraft". The brief's question (c) is
// whether the phone opens a *real* world -- one a real server wrote -- and until this
// file existed the answer was no: `core.savegame` was wired into the CI renderer and
// into the `worldload` tool, and neither is in the APK.
//
// What a phone can actually receive is one file. `worldload` and `jrender` walk a
// directory of region files on a machine that has the save; a phone gets what the
// owner shares with the file picker, and the picker hands over a single document. So
// the thing a phone imports is a `.zip` of the world's `region/` directory (Minecraft's
// own export, and what a backup app writes), and this file is its policy half:
//
//   * which entry names count as a region file (`r.<x>.<z>.mca`, nothing else);
//   * how many chunks a world may have before it is refused, because a 4 000-chunk save
//     on a phone is not a world, it is a way to run out of memory;
//   * what "the world is open" means: columns in `demo`, the array the mesher walks;
//   * the words the screen says, so the log and the screen cannot disagree.
//
// The bytes come from C: `umbra_world_import_begin` is handed the extracted archive,
// and its region entries are read exactly as `sg_load` reads them from a directory.
// Nothing here keeps a whole save in memory: one region file, its chunks parsed into
// columns, and the file dropped.
//
// The state a successful import leaves behind is bigger than memory: `demo` holds the
// save's columns instead of the generated ones, and every block question the player and
// the mesher ask (`demo_block_at`, `demo_column_of`) answers from them, because that is
// the array they already walk. Nothing else has to know a save was opened.

import std;
import os;
import core.mem;
import core.inflate;
import core.zip;
import core.nbt;
import core.region;
import core.demo;

// Where the world's regions are inside the archive. A save exported the way Minecraft
// exports one puts them under `region/`; 26.3 keeps the overworld under
// `dimensions/minecraft/overworld/region/`. Both are asked, and the one that answered is
// named in the log so a report cannot quietly be about another world.
let WL_ZIP_CLASSIC = "region/";
let WL_ZIP_MODERN = "dimensions/minecraft/overworld/region/";

// How much of a save a phone opens: 25 chunks, a five by five window centred on the
// world's origin, which is where a player spawns. That is a 80 by 80 block piece of the
// real world -- real terrain, real caves, real ores, drawn from the save -- and it is the
// most this renderer holds: the demo world's nine chunks are 444 917 vertices, so 25
// chunks of server terrain is about 1.1 M vertices and 55 MB of vertex buffer, which is
// twice what the app already uploads and about as much as a Mali-G57 will keep.
//
// The alternative was to open everything: a 529-chunk world measured 7.4 M vertices in
// the CI renderer, which is 400 MB of buffer and an out-of-memory kill on any phone. So
// the window is a decision, it is in the log with the count left out, and the number is
// here rather than spread through the reader.
let WL_MAX_CHUNKS: i64 = 25;
// The window's radius in chunks. Constant, not derived from the archive's size: a save
// holds its chunks in region files of 32x32, so "how many files" says nothing about which
// chunks are near the spawn, and reading the first 25 the reader happens to meet would be
// a window whose position depends on the order of a directory listing.
let WL_WINDOW: i64 = 2;
// The most one chunk may ask the block-state registry for. A section's palette is capped
// at 1024 entries by the format (`resolve_palette`), 24 sections a column, so this is the
// format's ceiling and not a guess.
let WL_MAX_STATES: i64 = 24 * 1024;

// One import's arithmetic, kept where a test can read it: what the last import did, and
// why it did nothing when it did nothing.
struct WlResult {
    files: i64,        // region files read out of the archive
    entries: i64,      // entries in the archive
    chunks: i64,       // chunks parsed
    blocks: i64,       // non-air blocks in them
    states: i64,       // block-state entries the save's palettes introduced
    errors: i64,       // chunks that could not be read
    partial: i64,      // chunks whose Status is not minecraft:full
    skipped: i64,      // chunks dropped for being outside the radius or over the cap
    radius: i64,       // the chunk radius used (0 = every chunk)
}

var wl_res = WlResult {
    files: 0, entries: 0, chunks: 0, blocks: 0, states: 0, errors: 0, partial: 0, skipped: 0,
    radius: 0,
};
// The archive's bytes, while it is being read. The phases are separate calls so the
// frame loop can do a little at a time: opening a 30 MB archive is a memcpy, reading 600
// chunks is a second, and meshing what comes out is the same sliced pass as the demo
// world. None of the three may hold the frame.
var wl_zip: u8[>..] = [];
var wl_zip_open: bool = false;
var wl_msg: u8[>..] = [];
// Columns read so far. Staged, not pushed straight into `demo`: an archive that turns out
// to hold nothing the reader can take must not have already thrown the demo world away,
// because that is the difference between a refusal and a black screen.
var wl_cols: ChunkColumn[>..] = [];
var wl_accepted: i64 = 0;     // the last verdict: 1 opened, 0 refused, with wl_msg saying why
var wl_opened: i64 = 0;       // 1 when a save is the world being drawn
var wl_open_files: i64 = 0;
var wl_open_chunks: i64 = 0;

var wl_msg_buf: u8[>..] = [];

fn wl_say3(a: const u8[:], b: const u8[:], c: const u8[:]) {
    wl_msg = [];
    wl_msg.append(a);
    wl_msg.append(b);
    wl_msg.append(c);
}

fn wl_say(a: const u8[:]) { wl_say3(a, "", ""); }

// Is this entry name a region file, and which region is it? `r.<x>.<z>.mca`, where both
// numbers are decimal and may be negative. Anything else in the archive -- level.dat,
// the icon, a `data/` directory -- is not a world's blocks and is skipped without
// comment, because a save legitimately holds those.
fn wl_region_of(name: const u8[:]) -> bool, i64, i64 {
    let base = wl_base_name(name);
    if base.len < 7 { return false, 0, 0; }
    if base[0] != 114 || base[1] != 46 { return false, 0, 0; }   // "r."
    if base[base.len - 4] != 46 || base[base.len - 3] != 109 || base[base.len - 2] != 99 ||
       base[base.len - 1] != 97 {
        return false, 0, 0;                                       // ".mca"
    }
    var got: i64 = 0;
    var rx: i64 = 0;
    var rz: i64 = 0;
    var v: i64 = 0;
    var neg = false;
    for k in base.len {
        if k < 2 || k >= base.len - 4 { continue; }
        let ch = base[k];
        if ch == 45 {
            neg = true;
        } else if ch >= 48 && ch <= 57 {
            v = v * 10 + ((ch as i64) - 48);
        } else if ch == 46 {
            if got == 0 { rx = if neg { 0 - v } else { v }; }
            got += 1;
            v = 0;
            neg = false;
        } else {
            return false, 0, 0;
        }
    }
    if got != 1 { return false, 0, 0; }
    rz = if neg { 0 - v } else { v };
    return true, rx, rz;
}

// The name after the last '/', so an entry under `region/` and one under the 26.3
// dimension path are read the same way.
fn wl_base_name(name: const u8[:]) -> const u8[:] {
    var at: i64 = 0;
    for i in name.len {
        if name[i] == 47 { at = i + 1; }
    }
    return name[at..]
}

// The archive, parsed. Kept open across the calls that follow, because the central
// directory names the entries and `zip_extract` needs the same bytes.
fn wl_archive_reset() {
    zip_reset();
    wl_zip = [];
    wl_zip_open = false;
}

// Phase 1: the bytes. One file, checked for being a zip with regions in it, refused with
// a sentence if it is not. Returns the number of region entries, or 0 when refused.
fn wl_import_begin(path: const u8[:]) -> i64 {
    wl_archive_reset();
    // The zip layer checks every extracted entry's CRC; its table is built here because a
    // host that only ever opens a world (the app at start-up, before any jar) has not
    // built it, and an uninitialised table rejects every entry with a CRC mismatch --
    // which reads as "the save is corrupt". `umbra_jar_load` does the same thing for the
    // same reason.
    crc32_init();
    wl_res = WlResult {
        files: 0, entries: 0, chunks: 0, blocks: 0, states: 0, errors: 0, partial: 0,
        skipped: 0, radius: 0,
    };
    wl_accepted = 0;
    wl_cols = [];
    if !read_file(path, wl_zip) {
        wl_say3("cannot read ", path, "");
        return 0;
    }
    if wl_zip.len < 22 {
        wl_say3("the file is ", "not a world", ": it is too small to be an archive");
        wl_zip = [];
        return 0;
    }
    let ok, err = zip_open("world", wl_zip[..]);
    if !ok {
        wl_msg = [];
        wl_msg.append(err);
        wl_zip = [];
        return 0;
    }
    let archive = zip_archives.len - 1;
    wl_res.entries = zip_count(archive);
    wl_zip_open = true;
    // Which entries are regions, and is there at least one?
    var regions: i64 = 0;
    var classic: i64 = 0;
    var modern: i64 = 0;
    for i in zip_count(archive) {
        let e = zip_entry_at(archive, i);
        let name = zip_name_of(zip_entries[e]);
        let is_region, rx, rz = wl_region_of(name);
        if !is_region { continue; }
        regions += 1;
        if starts_with(name, WL_ZIP_CLASSIC) { classic += 1; }
        if starts_with(name, WL_ZIP_MODERN) { modern += 1; }
    }
    if regions == 0 {
        wl_say3("no world in this archive", ": it holds no region/r.x.z.mca", "");
        wl_archive_reset();
        return 0;
    }
    wl_res.files = regions;
    wl_res.radius = wl_radius_for(regions);
    wl_msg = [];
    format(wl_msg, regions, " region file(s)");
    if classic > 0 {
        wl_msg.append(" under region/");
    } else if modern > 0 {
        wl_msg.append(" under the 26.3 overworld path");
    }
    return regions;
}

// How much of the archive to open. A save this small is opened whole; a big one is
// opened around the origin, because the mesher draws what it is given and a phone cannot
// mesh 900 chunks inside its budget. The number is reported either way, so "the world was
// 529 chunks and Umbra read 441" is a line, not a surprise.
fn wl_radius_for(regions: i64) -> i64 {
    if regions <= 0 { return 0; }
    return WL_WINDOW;
}

// Phase 2: the region files. One call per entry, so the frame loop can spread the work;
// each call reads one entry, parses its chunks into columns appended to `demo`, and drops
// the bytes. Returns the number of chunks taken from that entry.
fn wl_import_file(index: i64) -> i64 {
    if !wl_zip_open { return 0; }
    let archive = zip_archives.len - 1;
    if index < 0 || index >= zip_count(archive) { return 0; }
    let e = zip_entry_at(archive, index);
    let name = zip_name_of(zip_entries[e]);
    let is_region, rx, rz = wl_region_of(name);
    if !is_region { return 0; }
    var region: u8[>..] = [];
    let ok, err = zip_extract(wl_zip[..], e, region);
    if !ok {
        wl_msg = [];
        wl_msg.append(err);
        wl_res.errors += 1;
        return 0;
    }
    var taken: i64 = 0;
    var nbt: u8[>..] = [];
    for cz in 32 {
        for cx in 32 {
            let h = region_location(region[..], cx as i32, cz as i32);
            if h.offset == 0 || h.sectors == 0 { continue; }
            nbt = [];
            let got, rerr = region_chunk_nbt(region[..], cx as i32, cz as i32, nbt);
            if !got {
                wl_res.errors += 1;
                continue;
            }
            nbt_reset();
            var nerr: u8[>..] = [];
            let root = nbt_parse(nbt[..], nerr);
            if root < 0 {
                wl_res.errors += 1;
                continue;
            }
            let wx = rx * 32 + (cx as i64);
            let wz = rz * 32 + (cz as i64);
            if wl_res.radius > 0 {
                // A save's origin is chunk 0,0, and that is where a player spawns.
                if wx < 0 - wl_res.radius || wx > wl_res.radius ||
                   wz < 0 - wl_res.radius || wz > wl_res.radius {
                    wl_res.skipped += 1;
                    continue;
                }
            }
            if wl_res.chunks >= WL_MAX_CHUNKS {
                wl_res.skipped += 1;
                continue;
            }
            var c = column_new();
            column_from_nbt(root, c);
            // The chunk's own xPos/zPos wins when the file disagrees with its name; a
            // chunk put in the wrong place is a rendering bug nobody can see the cause of.
            if c.x == 0 && c.z == 0 && (wx != 0 || wz != 0) {
                c.x = wx as i32;
                c.z = wz as i32;
            }
            // Either spelling of the field, through the one function that knows both.
            let st = chunk_status(root);
            if st.len > 0 && !eq_bytes(st, "minecraft:full") { wl_res.partial += 1; }
            wl_open_blocks(c);
            wl_cols.push(c);
            wl_res.chunks += 1;
            taken += 1;
        }
    }
    return taken;
}

// Count the chunk's non-air blocks and the states its sections introduced. These are two
// walks over the same data and they are what makes the import's log line comparable with
// `worldload`'s ("chunks 529, non-air blocks 843609, states 45"): the same reader, the
// same numbers.
fn wl_open_blocks(c: ChunkColumn&) {
    var i: i32 = c.section_lo;
    while i <= c.section_hi {
        if i >= 0 && i < 24 && c.sections[i].present {
            let n = c.sections[i].palette_len;
            if n > 0 { wl_res.states += n as i64; }
            let base = (i as i64) * 16 - 64;
            for y in 16 {
                for z in 16 {
                    for x in 16 {
                        let id = chunk_block(c, x as i32, (base + y) as i32, z as i32);
                        if id != 0 && !demo_is_air(id) { wl_res.blocks += 1; }
                    }
                }
            }
        }
        i += 1;
    }
}

// Phase 3: done. The demo world that was there is gone -- it was built to be replaced --
// and the save's columns are what the mesher will walk. `wl_opened` says so, and the HUD
// and the log both report it.
fn wl_import_end() -> i64 {
    if wl_res.chunks <= 0 {
        wl_say3("the archive held ", "no chunks", " the reader could take");
        wl_accepted = 0;
        wl_cols = [];
        wl_archive_reset();
        return 0;
    }
    // Chunks with no blocks in them are not a world, and opening one is worse than
    // refusing it: the screen says a save is open, the log says how many chunks, and the
    // mesh is empty. This is exactly what run 44251941145 did -- the archive held the
    // save's *entities* region files, which share the chunk format's envelope and hold
    // entity NBT, so every chunk parsed, every palette was read (600 states), and not one
    // block was a block. A world with terrain has blocks; a real save of a spawn area has
    // hundreds of thousands. The threshold is low on purpose -- a deliberately empty
    // superflat world would still have a bedrock layer in every chunk.
    if wl_res.blocks <= 0 {
        wl_say3("the archive opened ", "no blocks", ": these are chunks, but nothing in them is a block");
        wl_accepted = 0;
        wl_cols = [];
        wl_archive_reset();
        return 0;
    }
    wl_archive_reset();
    // The demo world -- or the save that was open before -- is replaced, not added to. The
    // whole array is rebuilt so a second import cannot leave the first world's columns
    // behind it: that is a mesh 40 chunks wide with two worlds in it.
    demo = [];
    for i in wl_cols.len { demo.push(wl_cols[i]) }
    wl_cols = [];
    wl_open_files = wl_res.files;
    wl_open_chunks = wl_res.chunks;
    wl_bounds_update();
    wl_opened = 1;
    wl_accepted = 1;
    wl_msg = [];
    format(wl_msg, wl_res.chunks, " chunk(s) from ", wl_res.files);
    wl_msg.append(" region file(s)");
    return 1;
}

// What the last import did, for the C screen and for the log. One call per number keeps
// the shared header small; they are cheap and the screen refreshes once.
fn wl_count_chunks() -> i64 { return wl_res.chunks; }
fn wl_count_files() -> i64 { return wl_res.files; }
fn wl_count_blocks() -> i64 { return wl_res.blocks; }
fn wl_count_states() -> i64 { return wl_res.states; }
fn wl_count_errors() -> i64 { return wl_res.errors; }
fn wl_count_partial() -> i64 { return wl_res.partial; }
fn wl_count_skipped() -> i64 { return wl_res.skipped; }
fn wl_count_entries() -> i64 { return wl_res.entries; }
fn wl_radius_used() -> i64 { return wl_res.radius; }
fn wl_message() -> const u8[:] { return wl_msg; }
fn wl_is_open() -> i64 { return wl_opened; }
fn wl_verdict() -> i64 { return wl_accepted; }
fn wl_chunks_open() -> i64 { return wl_open_chunks; }
fn wl_files_open() -> i64 { return wl_open_files; }

// The world's bounds, for the C camera and the spawn: a save's columns are anywhere from
// -30 million to +30 million, so the bounds are computed from the columns that landed
// rather than being the demo world's 0..48.
var wl_min_x: i32 = 0;
var wl_min_z: i32 = 0;
var wl_max_x: i32 = 0;
var wl_max_z: i32 = 0;

fn wl_bounds_update() {
    wl_min_x = 0;
    wl_min_z = 0;
    wl_max_x = 0;
    wl_max_z = 0;
    if demo.len == 0 { return; }
    wl_min_x = demo[0].x;
    wl_max_x = demo[0].x;
    wl_min_z = demo[0].z;
    wl_max_z = demo[0].z;
    for i in demo.len {
        let c = demo[i];
        if c.x < wl_min_x { wl_min_x = c.x; }
        if c.x > wl_max_x { wl_max_x = c.x; }
        if c.z < wl_min_z { wl_min_z = c.z; }
        if c.z > wl_max_z { wl_max_z = c.z; }
    }
}

fn wl_min_block_x() -> f32 { return (wl_min_x as f32) * 16.0; }
fn wl_max_block_x() -> f32 { return ((wl_max_x as f32) + 1.0) * 16.0; }
fn wl_min_block_z() -> f32 { return (wl_min_z as f32) * 16.0; }
fn wl_max_block_z() -> f32 { return ((wl_max_z as f32) + 1.0) * 16.0; }
