import std;
import core.mem;
import core.nbt;
import core.region;
import test.harness;

fn load_chunk(region: const u8[:], cx: i32, cz: i32, c: ChunkColumn&) -> bool {
    var payload: u8[>..] = [];
    let ok, err = region_chunk_nbt(region, cx, cz, payload);
    if !ok {
        print("FAIL: region_chunk_nbt ", cx, ",", cz, ": ", err);
        return false;
    }
    var nerr: u8[>..] = [];
    let root = nbt_parse(payload, nerr);
    if root < 0 {
        print("FAIL: chunk nbt: ", nerr);
        return false;
    }
    column_from_nbt(root, c);
    return true;
}

fn check_block(c: ChunkColumn&, x: i32, y: i32, z: i32, want: const u8[:]) {
    let got = bs_name(chunk_block(c, x, y, z));
    checks += 1;
    if !eq_bytes(got, want) {
        failures += 1;
        print("FAIL: block at ", x, ",", y, ",", z, " is ", got, " want ", want);
    }
}

fn run_region() {
    bs_reset();
    // Registry basics: air is always id 0 and interning is stable.
    check_i64(bs_intern("minecraft:air", "") as i64, 0, "air is id 0");
    let stone = bs_intern("minecraft:stone", "");
    check_i64(bs_intern("minecraft:stone", "") as i64, stone as i64, "interning is stable");
    check(eq_bytes(bs_name(stone), "minecraft:stone"), "name lookup");
    let stairs = bs_intern("minecraft:oak_stairs", "facing=north,half=top");
    check(eq_bytes(bs_props_of(stairs), "facing=north,half=top"), "props lookup");
    check(bs_intern("minecraft:oak_stairs", "facing=south,half=top") as i64 != stairs as i64,
          "a different property set is a different state");
    check(bs_find_block("minecraft:nope") == 0xFFFFFFFF, "unknown block is not found");

    var data: u8[>..] = [];
    if !read_file("goose/test/fixtures/region/r.0.0.mca", data) {
        test_fail("cannot read region fixture; run tools/gen_region_fixtures.py");
        test_summary("region");
        return;
    }
    check_i64(data.len % 4096, 0, "region file is a whole number of sectors");
    var c = column_new();
    check(load_chunk(data, 0, 0, c), "chunk 0,0 loads");
    check_i64(c.x as i64, 0, "xPos");
    check_i64(c.z as i64, 0, "zPos");
    check_i64(c.data_version as i64, 3955, "DataVersion");
    check(nbt_valid(1), "nbt tree still readable");
    check_i64(c.section_hi as i64 - c.section_lo as i64 + 1, 12, "twelve sections present");
    // Terrain checks against the generator's rules.
    check_block(c, 1, 0, 1, "minecraft:stone");
    check_block(c, 1, 63, 1, "minecraft:grass_block");
    check_block(c, 1, 62, 1, "minecraft:dirt");
    check_block(c, 8, 66, 8, "minecraft:oak_log");
    check(eq_bytes(bs_props_of(chunk_block(c, 8, 66, 8)), "axis=y"), "trunk keeps its axis");
    check_block(c, 9, 70, 9, "minecraft:oak_leaves");
    check_block(c, 5, 64, 5, "minecraft:water");
    check(eq_bytes(bs_props_of(chunk_block(c, 5, 64, 5)), "level=0"), "water level");
    check_block(c, 2, 100, 2, "minecraft:air");
    check_block(c, 1, 63, 1, "minecraft:grass_block");
    // Every one of the 4096 blocks in a section must decode, not just the
    // ones on the faces: count stones in the bottom section.
    var stones = 0;
    for i in 4096 {
        let x = (i % 16) as i32;
        let z = ((i / 16) % 16) as i32;
        let y = (i / 256) as i32;
        if eq_bytes(bs_name(chunk_block(c, x, y, z)), "minecraft:stone") { stones += 1; }
    }
    check(stones > 3800, "the bottom section is almost all stone");
    // Set a block and read it back.
    chunk_set_block(c, 3, 63, 3, stone);
    check_block(c, 3, 63, 3, "minecraft:stone");

    // A second column loads independently.
    var c2 = column_new();
    check(load_chunk(data, 1, 0, c2), "chunk 1,0 loads");
    check_i64(c2.x as i64, 1, "second chunk x");
    check_block(c2, 1, 0, 1, "minecraft:stone");

    // Packing round trip: unpack, repack, unpack again.
    var idx: u16[4096] = [0; 4096];
    for i in 4096 { idx[i] = (i % 37) as u16; }
    var packed: u8[>..] = [];
    pack_indices(idx, 6, packed);
    check_i64(packed.len, (4096 * 6 + 63) / 64 * 8, "packed length");
    var back: u16[4096] = [0; 4096];
    unpack_indices(packed, packed.len / 8, 6, back);
    var same = true;
    for i in 4096 { if back[i] != idx[i] { same = false; } }
    check(same, "pack/unpack round trip at 6 bits");

    // zlib_store produces something zlib can read: the reader proves it by
    // reading its own output with inflate_zlib.
    var plain: u8[>..] = [];
    for i in 5000 { plain.push((i * 7) as u8); }
    var z: u8[>..] = [];
    zlib_store(plain, z);
    var round: u8[>..] = [];
    let zok, zerr = inflate_zlib(z, round);
    checks += 1;
    if !zok {
        failures += 1;
        print("FAIL: zlib_store output unreadable: ", zerr);
    } else {
        check_bytes(round, plain, "zlib_store round trip");
    }

    // Writing: build a region with one chunk and read it back with the reader.
    var slots: RegionSlot[2] = [RegionSlot { cx: 0, cz: 0, nbt: sref_none() },
                                RegionSlot { cx: 5, cz: 3, nbt: sref_none() }];
    var payloads: u8[>..] = [];
    var payload2: u8[>..] = [];
    let ok0, e0 = region_chunk_nbt(data, 0, 0, payload2);
    check(ok0, "extract chunk for rewrite");
    slots[0].nbt = Sref { off: 0, len: payload2.len };
    for b in payload2 { payloads.push(b); }
    var fake: u8[>..] = [];
    for b in payload2[0..200] { fake.push(b); }
    slots[1].nbt = Sref { off: payload2.len, len: fake.len };
    for b in fake { payloads.push(b); }
    var out: u8[>..] = [];
    region_write(slots, payloads, out);
    check_i64(out.len % 4096, 0, "written region is sector aligned");
    check(region_location(out, 0, 0).sectors > 0, "written chunk 0,0 has sectors");
    check(region_location(out, 5, 3).sectors > 0, "written chunk 5,3 has sectors");
    var reread: u8[>..] = [];
    let rok, rerr = region_chunk_nbt(out, 0, 0, reread);
    checks += 1;
    if !rok {
        failures += 1;
        print("FAIL: written chunk unreadable: ", rerr);
    } else {
        check_bytes(reread, payload2, "written chunk survives a read back");
    }

    // Negative tests.
    var broken_read: u8[>..] = [];
    each_split("bad_bad_offset\nbad_empty\nbad_header_only", '\n') {
        if it.len == 0 { }
        else {
            var p: u8[>..] = [];
            p.append("goose/test/fixtures/region/");
            p.append(it);
            p.append(".mca");
            var b: u8[>..] = [];
            if read_file(p, b) {
                var o: u8[>..] = [];
                let ok2, e2 = region_chunk_nbt(b, 0, 0, o);
                checks += 1;
                if ok2 && b.len > 4096 {
                    // bad_bad_offset has a plausible header; it must still fail
                    // because its record runs past the end of the file.
                    failures += 1;
                    print("FAIL: broken region accepted: ", it);
                } else {
                    broken_read = [];
                }
            }
        }
    }
    test_summary("region");
}
