import std;
import os;
import core.mem;
import core.zip;
import core.region;
import core.nbt;
import core.demo;
import core.worldload_in;
import test.harness;

// The app's world import, held to the same standard as the rest of the formats: the
// archive was written by Python's zipfile around a world `tools/make_test_world.py`
// wrote, and what the importer makes of it is compared with what a directory read of the
// same save makes of it. Two readers, one file, neither of them the writer.
//
// The checks that matter, in the order the brief asks for them:
//   * which entry names are region files (a save also holds level.dat, and one that does
//     not match must be refused, not opened as an empty world);
//   * both layouts (region/ and 26.3's dimensions/.../region/);
//   * the columns land in `demo` at the chunk coordinates the save names, including a
//     negative one, because a real world is centred on 0,0;
//   * the numbers match a direct read of the same region file.
fn run_worldzip() {
    wl_negative_chunk_test();
    wl_layout_test("world-classic.zip", "region/");
    wl_layout_test("world-modern.zip", "dimensions/minecraft/overworld/region/");
    wl_refusal_test();
    wl_no_blocks_test();
    wl_263_status_test();
    wl_cap_test();
    test_summary("worldzip");
}

// The block-position arithmetic a real save needs. The demo world is 0..47 and the first
// version of `demo_column_of` refused a negative coordinate outright; that was invisible
// while the only world was generated and would have made half of every real save's blocks
// unreachable. A column at -1,-1 owns blocks -16..-1, and the block at -1,-1 is its 15,15.
fn wl_negative_chunk_test() {
    bs_reset();
    let stone = bs_intern("minecraft:stone", "");
    demo = [];
    var c = column_new();
    c.x = -1;
    c.z = -1;
    c.present = true;
    var s = section_new();
    s.y = 0;
    s.present = true;
    c.sections[4] = s;
    c.section_lo = 4;
    c.section_hi = 4;
    chunk_set_block(c, 15, 0, 15, stone);
    chunk_set_block(c, 0, 0, 0, stone);
    demo.push(c);
    check(demo_column_of(-1, -1) == 0, "a column at -1,-1 is found by a negative position");
    check(demo_column_of(-16, -16) == 0, "and by the first position it owns");
    check(demo_column_of(0, 0) == -1, "a position in chunk 0,0 is not in it");
    check_i64(demo_block_at(-1, 0, -1) as i64, stone as i64, "the block at -1,-1 is its 15,15");
    check_i64(demo_block_at(-16, 0, -16) as i64, stone as i64, "and its 0,0 is at -16,-16");
    check(demo_set_block(-2, 0, -3, stone), "a negative position can be edited");
    check_i64(demo_block_at(-2, 0, -3) as i64, stone as i64, "and read back");
    demo = [];
}

// One archive, opened the way the app opens it: begin, one call per entry, end.
fn wl_layout_test(zip_name: const u8[:], prefix: const u8[:]) {
    bs_reset();
    demo = [];
    var path: u8[>..] = [];
    path.append("goose/test/fixtures/worldzip/");
    path.append(zip_name);
    let regions = wl_import_begin(path[..]);
    check(regions > 0, "the archive's region files are found");
    check(wl_verdict() == 0, "an archive is not 'opened' before it is read");
    // Every entry of the archive is offered; only the region ones are read. The number of
    // entries is larger than the number of regions, which is the point: level.dat is in
    // both archives and is not a world's blocks.
    check(wl_count_entries() > regions, "the archive holds entries that are not regions");
    var i: i64 = 0;
    while i < wl_count_entries() {
        wl_import_file(i);
        i += 1;
    }
    let opened = wl_import_end();
    check_i64(opened, 1, "the world opens");
    check_i64(wl_count_files() as i64, regions, "every region file was read");
    check_i64(wl_count_chunks() as i64, 4, "four chunks, as the fixture's save has");
    check_i64(wl_count_errors(), 0, "no chunk failed to read");
    check(wl_count_blocks() > 10000, "the world holds real blocks");
    check(wl_count_states() >= 4, "the sections introduced block states");
    check(demo.len as i64 == wl_count_chunks(), "one column per chunk");

    // The same save read the way the CI reader reads it: one region file, one chunk, and
    // the block at a known position. The archive and the directory hold identical bytes,
    // so the two must answer identically -- and a block's *name* is the answer that
    // survives the two readers having separate state registries.
    var dir_path: u8[>..] = [];
    dir_path.append("goose/test/fixtures/worldzip/save/");
    dir_path.append(prefix);
    var names: u8[>..] = [];
    check(list_dir(dir_path[..], names), "the same save is on disk as a directory");
    var region_bytes: u8[>..] = [];
    var region_path: u8[>..] = [];
    region_path.append(dir_path[..]);
    region_path.append("r.0.0.mca");
    check(read_file(region_path[..], region_bytes), "and its region file can be read");
    // The importer's world is in `demo`; a second read of the same chunk is compared with
    // it block by block, over the whole chunk, in the order names are cheapest to compare:
    // a count of differences, so a failure names a number rather than a position.
    var differ = 0;
    var compared = 0;
    for cz in 2 {
        for cx in 2 {
            var nbt: u8[>..] = [];
            let got, rerr = region_chunk_nbt(region_bytes[..], cx as i32, cz as i32, nbt);
            check(got, "a chunk of the directory copy reads");
            if !got { continue; }
            nbt_reset();
            var nerr2: u8[>..] = [];
            let root = nbt_parse(nbt[..], nerr2);
            check(root >= 0, "and its NBT parses");
            if root < 0 { continue; }
            var direct = column_new();
            column_from_nbt(root, direct);
            let xo = (cx * 16) as i32;
            let zo = (cz * 16) as i32;
            for y in -64..96 {
                for z in 16 {
                    for x in 16 {
                        let a = demo_block_at(xo + (x as i32), y as i32, zo + (z as i32));
                        let b = chunk_block(direct, x as i32, y as i32, z as i32);
                        compared += 1;
                        if !eq_bytes(bs_name(a), bs_name(b)) { differ += 1; }
                    }
                }
            }
        }
    }
    check(compared > 0, "the two reads were compared");
    check_i64(differ, 0, "the importer's columns are the save's blocks, block for block");

    // Trees, the slab and water in the fixture: three block kinds that are not terrain.
    var saw_log = false;
    var saw_water = false;
    var saw_leaves = false;
    var xo: i32 = 0;
    var zo: i32 = 0;
    for i2 in demo.len {
        xo = demo[i2].x * 16;
        zo = demo[i2].z * 16;
        for y in 56..75 {
            for z in 16 {
                for x in 16 {
                    let id = demo_block_at(xo + (x as i32), y as i32, zo + (z as i32));
                    if id == 0 { continue; }
                    let n = bs_name(id);
                    if ends_with(n, "oak_log") { saw_log = true; }
                    if ends_with(n, "water") { saw_water = true; }
                    if ends_with(n, "oak_leaves") { saw_leaves = true; }
                }
            }
        }
    }
    check(saw_log, "the imported world holds the tree");
    check(saw_water, "and the pond");
    check(saw_leaves, "and the leaves");
    demo = [];
    wl_reset_for_test();
}

// An archive with a level.dat and no region file is not a world. It has to be refused,
// with a sentence, rather than opened as a world of nothing -- which is what a naive
// "extract everything and see" would do.
fn wl_refusal_test() {
    demo = [];
    let regions = wl_import_begin("goose/test/fixtures/worldzip/world-not-a-world.zip");
    check_i64(regions, 0, "an archive with no region file is refused");
    check(wl_count_entries() > 0, "although its entries were listed");
    check_i64(wl_verdict() as i64, 0, "and it is not a world");
    check(wl_message().len > 0, "with a reason");
    check_i64(demo.len as i64, 0, "and no columns");
    // A file that is not an archive at all.
    let regions2 = wl_import_begin("goose/test/fixtures/region/r.0.0.mca");
    check_i64(regions2, 0, "a raw region file is not an archive");
    check(wl_message().len > 0, "and says so");
    demo = [];
    wl_reset_for_test();
}

// A world with chunks and no blocks. This is not hypothetical: a save stores its entities
// in region files with the same names in a directory beside the real ones, and an import
// that opens those reports "25 chunks, 600 states, 0 non-air blocks" -- which is what run
// 44251941145 said on the phone, with an empty mesh behind it. The envelope is valid, so
// only the block count can tell them apart, and the import now refuses on that count.
fn wl_no_blocks_test() {
    demo = [];
    let regions = wl_import_begin("goose/test/fixtures/worldzip/world-no-blocks.zip");
    check(regions >= 1, "an entities-style archive does hold region files");
    let entries = wl_count_entries();
    for i in entries { wl_import_file(i); }
    let ended = wl_import_end();
    check_i64(ended, 0, "but a world with no blocks in it is refused");
    check_i64(wl_verdict(), 0, "and is not called a world");
    check_i64(wl_count_blocks(), 0, "because there are no blocks to draw");
    check(wl_message().len > 0, "with a reason a person can read");
    check_i64(demo.len, 0, "and the demo world is not replaced by nothing");
    // The sentence has to say what is wrong, not just that something is.
    let msg = wl_message();
    var has_no = false;
    var i = 0;
    while i + 6 <= msg.len {
        if msg[i] == 'n' && msg[i + 1] == 'o' && msg[i + 2] == ' ' &&
           msg[i + 3] == 'b' && msg[i + 4] == 'l' && msg[i + 5] == 'o' { has_no = true; }
        i += 1;
    }
    check(has_no, "and the reason names the blocks");
    demo = [];
    wl_reset_for_test();
}

// A complete save from 26.3, which writes the chunk's status field as `status` instead of
// `Status`. Nothing about the world changes; only the spelling does. A reader that knows
// one spelling finds no status, calls every chunk unfinished, and reports a finished world
// as a half-generated one -- run 44279451494, "528 of 529 chunks are not minecraft:full
// yet" over 844 904 non-air blocks.
fn wl_263_status_test() {
    demo = [];
    let regions = wl_import_begin("goose/test/fixtures/worldzip/world-263-status.zip");
    check(regions >= 1, "a 26.3 save is an archive of region files");
    for i in wl_count_entries() { wl_import_file(i); }
    let ended = wl_import_end();
    check_i64(ended, 1, "a 26.3 save opens");
    check(wl_count_chunks() > 0, "with chunks");
    check(wl_count_blocks() > 0, "and blocks");
    // The point of the test: `partial` counts chunks whose status is not minecraft:full,
    // and the field is `status` here. Zero is the only right answer.
    check_i64(wl_count_partial(), 0, "and none of its chunks is called unfinished");
    // The same archive under the classic spelling, so the check cannot pass by counting
    // nothing at all.
    demo = [];
    wl_reset_for_test();
    let classic = wl_import_begin("goose/test/fixtures/worldzip/world-classic.zip");
    check(classic >= 1, "the classic-spelling archive is readable too");
    for i in wl_count_entries() { wl_import_file(i); }
    check_i64(wl_import_end(), 1, "and opens");
    check_i64(wl_count_partial(), 0, "with no unfinished chunks either");
    check(wl_count_blocks() > 0, "and blocks, the same way");
    demo = [];
    wl_reset_for_test();
}

// The chunk cap. A save bigger than a phone can mesh is opened around its origin rather
// than refused outright, and what was left out is counted instead of silently missing:
// "the world was 529 chunks and Umbra read 441" is a line in the log.
fn wl_cap_test() {
    check(WL_MAX_CHUNKS >= 16, "the cap is a piece of a world, not a demo");
    check(WL_MAX_CHUNKS <= 64, "and not more than a phone can hold in buffers");
    check_i64(wl_radius_for(1), WL_WINDOW, "the window is centred on the world's origin");
    check_i64(wl_radius_for(64), WL_WINDOW, "and does not depend on how many files there are");
    check(WL_WINDOW <= 4, "the window is small enough that the cap is rarely reached");
}

// The radius of the last import: set by the fixture, and 0 because its save is one region.
fn world_import_radius_after_begin() -> i64 {
    return 0;
}

// Between the tests: the module's state is a whole world, and leaving it would make the
// next test's counts nonsense. Nothing in the app calls this; the test does.
fn wl_reset_for_test() {
    demo = [];
}
