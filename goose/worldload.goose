// Umbra world load: read a real Anvil world with the same code the mesher uses, and
// say what is in it in a form two independent readers can compare.
//
//   umbra_worldload <world dir> <dump.txt> [detail radius] [jobs]
//
// The world directory is a save's folder: `region/*.mca` is read, each chunk's NBT is
// parsed, and the blocks go through `column_from_nbt` - the path the game's own chunks
// take - so what this prints is what the renderer would draw. Nothing here invents a
// block: the names, properties and positions all come out of the server's own files.
//
// The output is deliberately dull so that a second implementation can be compared with
// it exactly:
//   chunk <cx> <cz> blocks <n> hash <h>     one line per chunk, in sorted order
//   block <name>[<props>] <count>           one line per block state, sorted by name
//   total <chunks> <blocks> <states>
// and, for the chunks within `detail radius` of the origin, a `detail <x> <y> <z> <name>
// [<props>]` line for every non-air block, sorted by position. The hash covers exactly
// those records, so a reader that agrees on the hash agrees on every block.

import std;
import os;
import core.region;
import core.nbt;

var wl_region: u8[>..] = [];     // one region file
var wl_nbt: u8[>..] = [];        // one chunk's decompressed NBT
var wl_err: u8[>..] = [];

// The canonical order a block record is hashed in: y, then z, then x, and the name and
// properties of the state. FNV-1a, 64 bit, over single bytes.
var wl_hash: u64 = 14695981039346656037;

fn wl_hash_byte(b: u8) {
    wl_hash = (wl_hash ^ (b as u64)) * 1099511628211;
}

fn wl_hash_i32(v: i32) {
    var x = v;
    for k in 4 {
        wl_hash_byte((x & 0xFF) as u8);
        x = x >> 8;
    }
}

fn wl_hash_str(s: const u8[:]) {
    for b in s { wl_hash_byte(b); }
    wl_hash_byte(0);
}

// Block states, counted. A linear list is enough: a world has a few hundred states and
// a scan over them costs less than keeping a map.
var wl_state_name: u8[>..] = [];
var wl_state_off: i64[>..] = [];
var wl_state_len: i64[>..] = [];
var wl_state_props: i64[>..] = [];
var wl_state_count: i64[>..] = [];

fn wl_state_key(name: const u8[:]) -> i64 {
    var idx: i64 = -1;
    for i in wl_state_off.len {
        if wl_state_len[i] != name.len as i64 { continue; }
        var same = true;
        for k in name.len {
            if wl_state_name[wl_state_off[i] + k] != name[k] { same = false; break; }
        }
        if same { idx = i; break; }
    }
    if idx >= 0 { return idx; }
    let off = wl_state_name.len;
    for b in name { wl_state_name.push(b); }
    wl_state_off.push(off);
    wl_state_len.push(name.len as i64);
    wl_state_props.push(0);
    wl_state_count.push(0);
    return wl_state_off.len - 1;
}

// The props of the state, as the registry holds them (a slice of the interned table).
fn wl_state_props_of(id: u32) -> u8[:] { return bs_props_of(id) }

fn wl_is_air(name: const u8[:]) -> bool {
    if eq_bytes(name, "minecraft:air") { return true; }
    if eq_bytes(name, "minecraft:cave_air") { return true; }
    if eq_bytes(name, "minecraft:void_air") { return true; }
    return false;
}

fn wl_detail(out: u8[>..]&, x: i32, y: i32, z: i32, name: const u8[:], props: const u8[:]) {
    out.append("detail ");
    format(out, x, " ", y, " ", z, " ", name);
    if props.len > 0 {
        out.append("[");
        out.append(props);
        out.append("]");
    }
    out.append("\n");
}

fn wl_usage() {
    print("usage: umbra_worldload <world dir> <dump.txt> [detail radius] [out region]\n");
    exit(2);
}

fn wl_int_arg(i: i64, def: i64) -> i64 {
    if arg_count() <= i { return def; }
    var raw: u8[>..] = [];
    arg(i, raw);
    var v: i64 = 0;
    for k in raw.len {
        let d = (raw[k] as i64) - 48;
        if d < 0 || d > 9 { return def; }
        v = v * 10 + d;
    }
    return v;
}

fn main() {
    if arg_count() < 3 { wl_usage(); }
    var dir: u8[>..] = [];
    arg(1, dir);
    var out_path: u8[>..] = [];
    arg(2, out_path);
    let radius = wl_int_arg(3, 1);

    // Where the regions are depends on the version: the classic layout keeps the
    // overworld in `<world>/region`, and 26.3 keeps it in
    // `<world>/dimensions/minecraft/overworld/region`. Both are asked, in that order, and
    // the one that answered is named in the output so the two readers' logs can be
    // compared and neither can quietly read a different world.
    var region_dir: u8[>..] = [];
    var names: u8[>..] = [];
    var probe: u8[>..] = [];
    probe.append(dir[..]);
    probe.append("/region");
    var found = list_dir(probe[..], names);
    if found {
        region_dir.append(dir[..]);
        region_dir.append("/region");
    } else {
        probe = [];
        probe.append(dir[..]);
        probe.append("/dimensions/minecraft/overworld/region");
        if list_dir(probe[..], names) {
            found = true;
            region_dir.append(dir[..]);
            region_dir.append("/dimensions/minecraft/overworld/region");
        }
    }
    if !found {
        print("worldload: FAIL cannot list ", dir, "/region (nor the 26.3 overworld path)\n");
        exit(1);
    }
    print("worldload: region dir ", region_dir, "\n");

    var summary: u8[>..] = [];     // the machine-readable part
    var detail: u8[>..] = [];      // the block-by-block part
    var chunks: i64 = 0;
    var blocks: i64 = 0;
    var read_errors: i64 = 0;
    var files: i64 = 0;

    // list_dir hands back one name per line.
    var i: i64 = 0;
    while i < names.len {
        var j = i;
        while j < names.len && names[j] != '\n' { j += 1; }
        let name = names[i..j];
        i = j + 1;
        if !ends_with(name, ".mca") { continue; }
        files += 1;
        var path: u8[>..] = [];
        for b in region_dir { path.push(b); }
        path.append("/");
        for b in name { path.push(b); }
        wl_region = [];
        if !read_file(path[..], wl_region) {
            print("worldload: cannot read ", path, "\n");
            read_errors += 1;
            continue;
        }
        // r.<rx>.<rz>.mca: the 32x32 chunk square this file holds.
        var nums: i64[2] = [0, 0];
        var got: i64 = 0;
        var k: i64 = 2;
        while k < name.len && got < 2 {
            if name[k] == '-' || (name[k] >= '0' && name[k] <= '9') {
                var v: i64 = 0;
                var neg = false;
                if name[k] == '-' { neg = true; k += 1; }
                while k < name.len && name[k] >= '0' && name[k] <= '9' {
                    v = v * 10 + ((name[k] as i64) - 48);
                    k += 1;
                }
                nums[got] = if neg { 0 - v } else { v };
                got += 1;
            } else {
                k += 1;
            }
        }
        for cz in 32 {
            for cx in 32 {
                let wx = nums[0] * 32 + (cx as i64);
                let wz = nums[1] * 32 + (cz as i64);
                let lx = cx as i32;
                let lz = cz as i32;
                let h = region_location(wl_region[..], lx, lz);
                if h.offset == 0 || h.sectors == 0 { continue; }
                wl_nbt = [];
                let ok, err = region_chunk_nbt(wl_region[..], lx, lz, wl_nbt);
                if !ok {
                    print("worldload: ", path, " chunk ", wx, ",", wz, ": ", err, "\n");
                    read_errors += 1;
                    continue;
                }
                wl_err = [];
                let root = nbt_parse(wl_nbt[..], wl_err);
                if root < 0 {
                    print("worldload: ", path, " chunk ", wx, ",", wz, ": ", wl_err, "\n");
                    read_errors += 1;
                    continue;
                }
                var c = column_new();
                column_from_nbt(root, c);
                let ccx = c.x as i64;
                let ccz = c.z as i64;
                // Chunk NBT may hold only some sections; the rest stays air, which is
                // what the game means by a section it did not write.
                var count: i64 = 0;
                wl_hash = 14695981039346656037;
                let detailed = ccx >= 0 - radius && ccx <= radius && ccz >= 0 - radius && ccz <= radius;
                // y ascending, then z, then x: one canonical order for both readers.
                for y in -64..320 {
                    for z in 16 {
                        for x in 16 {
                            let id = chunk_block(c, x as i32, y as i32, z as i32);
                            if id == 0 { continue; }
                            let bname = bs_name(id);
                            if wl_is_air(bname) { continue; }
                            let props = wl_state_props_of(id);
                            let gx = (ccx * 16 + x) as i32;
                            let gz = (ccz * 16 + z) as i32;
                            wl_hash_i32(gx);
                            wl_hash_i32(y as i32);
                            wl_hash_i32(gz);
                            wl_hash_str(bname);
                            wl_hash_str(props);
                            count += 1;
                            let s = wl_state_key(bname);
                            wl_state_count[s] += 1;
                            if detailed {
                                wl_detail(detail, gx, y as i32, gz, bname, props);
                            }
                        }
                    }
                }
                summary.append("chunk ");
                format(summary, ccx, " ", ccz, " blocks ", count, " hash ", wl_hash, "\n");
                chunks += 1;
                blocks += count;
            }
        }
    }

    if chunks == 0 {
        print("worldload: FAIL no chunks: ", region_dir, " holds ", files, " region file(s)\n");
        exit(1);
    }

    // Per state, sorted by name: a stable order that does not depend on how the chunks
    // happened to be read.
    var order: i64[>..] = [];
    for s in wl_state_count.len { order.push(s); }
    // Selection sort: a few hundred entries, and it keeps the output independent of
    // the order the chunks were read in.
    for a in order.len {
        var best = a;
        for b in a + 1 .. order.len {
            if wl_state_compare(order[b], order[best]) < 0 { best = b; }
        }
        if best != a {
            let t = order[a];
            order[a] = order[best];
            order[best] = t;
        }
    }
    var states: i64 = 0;
    for k in order.len {
        let s = order[k];
        if wl_state_count[s] == 0 { continue; }
        var line: u8[>..] = [];
        line.append("block ");
        for b in wl_state_name[wl_state_off[s] .. wl_state_off[s] + wl_state_len[s]] { line.push(b); }
        line.append(" ");
        format(line, wl_state_count[s], "\n");
        summary.append(line[..]);
        states += 1;
    }
    var total: u8[>..] = [];
    total.append("total ");
    format(total, chunks, " ", blocks, " ", states, "\n");
    summary.append(total[..]);

    var out: u8[>..] = [];
    out.append(summary[..]);
    out.append(detail[..]);
    if !write_file(out_path[..], out[..]) {
        print("worldload: FAIL cannot write ", out_path, "\n");
        exit(1);
    }
    print("worldload: chunks ", chunks, ", non-air blocks ", blocks, ", states ", states,
          ", region files ", files, ", read errors ", read_errors, "\n");
    print("worldload: detail lines for chunks within ", radius, " of the origin\n");
    if read_errors > 0 {
        print("worldload: FAIL ", read_errors, " chunks could not be read\n");
        exit(1);
    }
    print("worldload: PASS - every chunk in the save was read\n");
}

// Name order, byte by byte: the comparison script sorts the same way.
fn wl_state_compare(a: i64, b: i64) -> i64 {
    let an = wl_state_name[wl_state_off[a] .. wl_state_off[a] + wl_state_len[a]];
    let bn = wl_state_name[wl_state_off[b] .. wl_state_off[b] + wl_state_len[b]];
    let n = if an.len < bn.len { an.len } else { bn.len };
    for k in n {
        if an[k] < bn[k] { return -1; }
        if an[k] > bn[k] { return 1; }
    }
    if an.len < bn.len { return -1; }
    if an.len > bn.len { return 1; }
    return 0;
}
