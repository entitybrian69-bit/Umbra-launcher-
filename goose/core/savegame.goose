// Load a world from a save directory into the columns the mesher draws.
//
// This is the same reader `goose/worldload.goose` uses (region files, chunk NBT,
// `column_from_nbt`), factored out so the renderer can draw a save instead of the demo
// world: a picture of a real world is worth more than a picture of a world I generated to
// look like one, and it is the only way to see whether every block in that world has a
// model in the jar.
//
// The columns land in `demo`, the column array the mesher already walks, because that is
// what "the world the renderer draws" is. `sg_load` never keeps the region files: one is
// read, its chunks are parsed into columns, and it is dropped.

import std;
import os;
import core.region;
import core.nbt;
import core.demo;

var sg_region: u8[>..] = [];      // one region file at a time
var sg_nbt: u8[>..] = [];
var sg_err: u8[>..] = [];

struct SgStat {
    files: i64,
    chunks: i64,
    blocks: i64,
    errors: i64,
}

// The classic layout keeps the overworld in <world>/region; 26.3 keeps it in
// <world>/dimensions/minecraft/overworld/region. Both are asked, in that order.
fn sg_region_dir(dir: const u8[:], out: u8[>..]&) -> bool {
    var probe: u8[>..] = [];
    probe.append(dir);
    probe.append("/region");
    var names: u8[>..] = [];
    if list_dir(probe[..], names) {
        out.append(probe[..]);
        return true;
    }
    probe = [];
    probe.append(dir);
    probe.append("/dimensions/minecraft/overworld/region");
    if list_dir(probe[..], names) {
        out.append(probe[..]);
        return true;
    }
    return false;
}

// r.<rx>.<rz>.mca, so the file's chunks are at world chunk (rx*32+cx, rz*32+cz).
fn sg_region_numbers(name: const u8[:], nums: i64[2]&) {
    nums[0] = 0;
    nums[1] = 0;
    var got = 0;
    var k: i64 = 2;
    while k < name.len as i64 && got < 2 {
        if name[k] == '-' || (name[k] >= '0' && name[k] <= '9') {
            var v: i64 = 0;
            var neg = false;
            if name[k] == '-' {
                neg = true;
                k += 1;
            }
            while k < name.len as i64 && name[k] >= '0' && name[k] <= '9' {
                v = v * 10 + ((name[k] as i64) - 48);
                k += 1;
            }
            nums[got] = if neg { 0 - v } else { v };
            got += 1;
        } else {
            k += 1;
        }
    }
}

// Read every region file under `dir` and append its chunks to `demo`. The block-state
// registry is expected to be empty (or to hold only what the mesher needs): the save's own
// names are interned as they are read, which is what makes `bs_name` answer for blocks the
// jar knows and for the ones it does not.
// `radius` limits the load to chunks within that many chunks of the origin (0 = every
// chunk). A real save can hold hundreds of chunks and millions of faces; the renderer in
// CI wants a picture and the numbers behind it, not the whole world.
fn sg_load(dir: const u8[:], apply: bool, radius: i64) -> SgStat {
    var stat = SgStat { files: 0, chunks: 0, blocks: 0, errors: 0 };
    var region_dir: u8[>..] = [];
    if !sg_region_dir(dir, region_dir) {
        print("save: no region directory under ", dir, "\n");
        stat.errors += 1;
        return stat;
    }
    print("save: region dir ", region_dir[..], "\n");
    var names: u8[>..] = [];
    if !list_dir(region_dir[..], names) {
        stat.errors += 1;
        return stat;
    }
    var i: i64 = 0;
    while i < names.len as i64 {
        var j = i;
        while j < (names.len as i64) && names[j] != '\n' { j += 1; }
        let name = names[i..j];
        i = j + 1;
        if !ends_with(name, ".mca") { continue; }
        stat.files += 1;
        var path: u8[>..] = [];
        path.append(region_dir[..]);
        path.append("/");
        path.append(name);
        sg_region = [];
        if !read_file(path[..], sg_region) {
            print("save: cannot read ", path[..], "\n");
            stat.errors += 1;
            continue;
        }
        var nums: i64[2] = [0, 0];
        sg_region_numbers(name, nums);
        for cz in 32 {
            for cx in 32 {
                let lx = cx as i32;
                let lz = cz as i32;
                let h = region_location(sg_region[..], lx, lz);
                if h.offset == 0 || h.sectors == 0 { continue; }
                sg_nbt = [];
                let ok, err = region_chunk_nbt(sg_region[..], lx, lz, sg_nbt);
                if !ok {
                    print("save: ", path[..], " chunk ", cx, ",", cz, ": ", err, "\n");
                    stat.errors += 1;
                    continue;
                }
                sg_err = [];
                let root = nbt_parse(sg_nbt[..], sg_err);
                if root < 0 {
                    print("save: ", path[..], " chunk ", cx, ",", cz, ": ", sg_err[..], "\n");
                    stat.errors += 1;
                    continue;
                }
                var c = column_new();
                column_from_nbt(root, c);
                // The chunk's own xPos/zPos is authoritative; the file's name is only
                // where to look. A file whose header and chunk disagree would otherwise
                // put the world in the wrong place.
                if c.x == 0 && c.z == 0 && (nums[0] != 0 || nums[1] != 0) {
                    c.x = (nums[0] * 32 + (cx as i64)) as i32;
                    c.z = (nums[1] * 32 + (cz as i64)) as i32;
                }
                if radius > 0 {
                    let ccx = c.x as i64;
                    let ccz = c.z as i64;
                    if ccx < 0 - radius || ccx > radius || ccz < 0 - radius || ccz > radius {
                        continue;
                    }
                }
                if apply {
                    var count: i64 = 0;
                    for y in -64..320 {
                        for z in 16 {
                            for x in 16 {
                                let id = chunk_block(c, x as i32, y as i32, z as i32);
                                if id == 0 { continue; }
                                if !demo_is_air(id) { count += 1; }
                            }
                        }
                    }
                    if count > 0 {
                        stat.blocks += count;
                    }
                    demo.push(c);
                }
                stat.chunks += 1;
            }
        }
    }
    return stat;
}
