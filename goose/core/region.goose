// Umbra core: the Anvil region file format (32x32 chunks per .mca file),
// paletted chunk sections, and the block-state registry they resolve into.
//
// The section layout follows minecraft.wiki's "Region file format" and
// "Chunk format" pages: a 4096-byte header of 1024 location/timestamp pairs,
// then chunk records of a 4-byte length, a 1-byte compression type and the
// NBT payload.

import std;
import core.mem;
import core.nbt;
import core.inflate;

// --- block state registry ----------------------------------------------
//
// A block state is a block name plus its property string, e.g.
// "minecraft:oak_stairs" with "facing=north,half=bottom". Worlds refer to
// states by name, the renderer wants a small integer: this interns them.

struct BlockStateDef {
    name: Sref,
    props: Sref,
    id: u32,
}

var bs_defs: BlockStateDef[>..] = [];
var bs_names: u8[>..] = [];
var bs_props: u8[>..] = [];

fn bs_reset() {
    bs_defs = [];
    bs_names = [];
    bs_props = [];
    // Id 0 is always air, which every chunk palette and every mesh relies on.
    bs_intern("minecraft:air", "");
}

fn bs_intern(name: const u8[:], props: const u8[:]) -> u32 {
    for d in bs_defs {
        let n = bs_names[d.name.off .. d.name.off + d.name.len];
        if n.len == name.len && eq_bytes(n, name) {
            let p = bs_props[d.props.off .. d.props.off + d.props.len];
            if p.len == props.len && eq_bytes(p, props) { return d.id; }
        }
    }
    let id = bs_defs.len as u32;
    let name_off = bs_names.len;
    for c in name { bs_names.push(c); }
    let props_off = bs_props.len;
    for c in props { bs_props.push(c); }
    bs_defs.push(BlockStateDef {
        name: Sref { off: name_off, len: name.len },
        props: Sref { off: props_off, len: props.len },
        id: id,
    });
    return id;
}

fn bs_name(id: u32) -> u8[:] {
    if id as i64 >= bs_defs.len { return bs_names[0..0]; }
    let d = bs_defs[id as i64];
    return bs_names[d.name.off .. d.name.off + d.name.len];
}

fn bs_props_of(id: u32) -> u8[:] {
    if id as i64 >= bs_defs.len { return bs_props[0..0]; }
    let d = bs_defs[id as i64];
    return bs_props[d.props.off .. d.props.off + d.props.len];
}

fn bs_find_block(name: const u8[:]) -> u32 {
    for d in bs_defs {
        let n = bs_names[d.name.off .. d.name.off + d.name.len];
        if n.len == name.len && eq_bytes(n, name) { return d.id; }
    }
    return 0xFFFFFFFF;
}

// The block name without its "minecraft:" namespace, which is what model and
// texture paths use.
fn bs_path(name: const u8[:]) -> u8[:] {
    var colon = -1;
    for i in name.len {
        if name[i] == ':' { colon = i; }
    }
    if colon < 0 { return name; }
    return name[colon + 1 .. name.len];
}

// --- chunk sections -----------------------------------------------------

struct Section {
    y: i32,
    present: bool,
    bits: u8,
    palette_len: i32,
    palette: u32[1024],     // block states, local order as the file has them
    blocks: u16[4096],      // global block-state ids, y*256 + z*16 + x
    biomes_len: i32,
    biomes: u32[64],        // biome ids, 4x4x4 cells, z*16 + x for the cell row
}

struct ChunkColumn {
    x: i32,
    z: i32,
    present: bool,
    data_version: i32,
    status: Sref,
    sections: Section[24],   // y = -4..19 in the current format
    section_lo: i32,         // lowest section index that is present
    section_hi: i32,
}

fn section_new() -> Section {
    var s = Section { y: 0, present: false, bits: 0, palette_len: 0,
                      palette: [0; 1024], blocks: [0; 4096],
                      biomes_len: 0, biomes: [0; 64] };
    return s;
}

fn column_new() -> ChunkColumn {
    var c = ChunkColumn { x: 0, z: 0, present: false, data_version: 0,
                          status: sref_none(), sections: [section_new(); 24],
                          section_lo: 24, section_hi: -1 };
    return c;
}

fn section_for_y(c: ChunkColumn&, sy: i32) -> i32 {
    let idx = sy + 4;
    if idx < 0 || idx >= 24 { return -1; }
    return idx;
}

fn chunk_block(c: ChunkColumn&, x: i32, y: i32, z: i32) -> u32 {
    if y < -64 || y > 319 { return 0; }
    // Section index in the column's fixed 24: the world bottom (-64) is 0.
    let idx = (y + 64) / 16;
    if idx < 0 { return 0; }
    let s = c.sections[idx];
    if !s.present { return 0; }
    let i = ((y & 15) * 256 + z * 16 + x) as i64;
    return s.blocks[i] as u32;
}

fn chunk_set_block(c: ChunkColumn&, x: i32, y: i32, z: i32, id: u32) {
    if y < -64 || y > 319 { return; }
    let idx = (y + 64) / 16;
    if idx < 0 { return; }
    if !c.sections[idx].present { return; }
    let i = ((y & 15) * 256 + z * 16 + x) as i64;
    // Write through the column's storage, not a copy of the section.
    c.sections[idx].blocks[i] = id as u16;
}

// --- NBT <-> section ----------------------------------------------------

// The properties of a block state, flattened to the "key=value,..." form the
// registry uses. Keys arrive in NBT order, which for a written state is the
// order the game sorts them in (alphabetical).
fn state_props_text(state: i64, out: u8[>..]&) {
    let props = nbt_child(state, "Properties");
    if !nbt_valid(props) { return; }
    var c = nbt_nodes[props].first;
    var first = true;
    while c >= 0 {
        if !first { out.push(','); }
        first = false;
        out.append(nbt_name(c));
        out.push('=');
        let p = nbt_nodes[c].payload;
        if sref_is_some(p) { out.append(nbt_payload[p.off .. p.off + p.len]); }
        c = nbt_nodes[c].next;
    }
}

fn state_name_text(state: i64) -> u8[:] {
    return nbt_string(state, "Name");
}

// Unpack a paletted container's long array into 4096 indices.
// Current format: entries packed contiguously with no per-long padding.
fn unpack_indices(data: const u8[:], count: i64, bits: i64, out: u16[4096]&) {
    if bits == 0 { return; }
    let mask: u64 = if bits >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << bits) - 1 };
    let per_long = 64 / bits;
    let packed_with_padding = count < (4096 * bits + 63) / 64 && per_long * count >= 4096;
    for i in 4096 {
        var v: u64 = 0;
        if packed_with_padding {
            // Older versions padded each long: values do not cross a boundary.
            let li = i / per_long;
            let within = i % per_long;
            let word = be_u64(data, li * 8);
            v = (word >> (within * bits)) & mask;
        } else {
            let bit = i * bits;
            let li = bit / 64;
            let shift = bit % 64;
            var word = be_u64(data, li * 8) >> shift;
            if shift + bits > 64 {
                let next = be_u64(data, (li + 1) * 8);
                word = word | (next << (64 - shift));
            }
            v = word & mask;
        }
        out[i] = v as u16;
    }
}

// Pack 4096 indices into a long array in the current (unpadded) format.
fn pack_indices(indices: u16[4096]&, bits: i64, out: u8[>..]&) {
    let longs = (4096 * bits + 63) / 64;
    var words: u64[1024] = [0; 1024];
    for i in 4096 {
        let bit = i * bits;
        let li = bit / 64;
        let shift = bit % 64;
        let v = indices[i] as u64;
        words[li] = words[li] | (v << shift);
        if shift + bits > 64 {
            words[li + 1] = words[li + 1] | (v >> (64 - shift));
        }
    }
    for i in longs { put_be_u64(out, words[i]); }
}

fn block_states_palette_len(block_states: i64) -> i64 {
    let palette = nbt_child(block_states, "palette");
    if !nbt_valid(palette) { return 0; }
    return nbt_nodes[palette].count;
}

fn resolve_palette(palette: i64, out: u32[1024]&) -> i32 {
    var n: i32 = 0;
    if !nbt_valid(palette) { return 0; }
    var c = nbt_nodes[palette].first;
    var props: u8[>..] = [];
    while c >= 0 {
        props = [];
        state_props_text(c, props);
        out[n as i64] = bs_intern(state_name_text(c), props);
        n += 1;
        if n >= 1024 { break; }
        c = nbt_nodes[c].next;
    }
    return n;
}

fn resolve_palette_biomes(palette: i64, out: u32[64]&) -> i32 {
    var n: i32 = 0;
    if !nbt_valid(palette) { return 0; }
    var c = nbt_nodes[palette].first;
    while c >= 0 {
        // Biome ids in the palette are plain names, interned in the same
        // table so one lookup serves blocks and biomes alike.
        if nbt_nodes[c].tag == 8 {
            out[n as i64] = bs_intern(nbt_bytes_at(c), "");
        } else {
            out[n as i64] = bs_intern(state_name_text(c), "");
        }
        n += 1;
        if n >= 64 { break; }
        c = nbt_nodes[c].next;
    }
    return n;
}

fn section_from_nbt(sec: i64, out: Section&) {
    out.y = nbt_int(sec, "Y", 0) as i32;
    out.present = true;
    let bs = nbt_child(sec, "block_states");
    if nbt_valid(bs) {
        let n = resolve_palette(nbt_child(bs, "palette"), out.palette);
        out.palette_len = n;
        let data_node = nbt_child(bs, "data");
        if n == 0 {
            // An empty section: everything is air.
            for i in 4096 { out.blocks[i] = 0; }
            out.bits = 0;
        } else if !nbt_valid(data_node) {
            // One palette entry and no data means the whole section is it.
            for i in 4096 { out.blocks[i] = out.palette[0] as u16; }
            out.bits = 0;
        } else {
            let count = nbt_nodes[data_node].count;
            var bits: i64 = 4;
            while ((1 as i64) << bits) < n { bits += 1; }
            // A single-entry palette still has 4-bit data; trust the array
            // length over a computed minimum, as the format's readers do.
            let p = nbt_nodes[data_node].payload;
            let data = nbt_payload[p.off .. p.off + p.len];
            var idx: u16[4096] = [0; 4096];
            unpack_indices(data, count, bits, idx);
            for i in 4096 {
                let pi = idx[i] as i32;
                if pi < n {
                    out.blocks[i] = out.palette[pi] as u16;
                } else {
                    out.blocks[i] = 0;
                }
            }
            out.bits = bits as u8;
        }
    }
    let biomes = nbt_child(sec, "biomes");
    if nbt_valid(biomes) {
        let n = resolve_palette_biomes(nbt_child(biomes, "palette"), out.biomes);
        out.biomes_len = n;
    }
}

fn column_from_nbt(root: i64, c: ChunkColumn&) {
    c.x = nbt_int(root, "xPos", 0) as i32;
    c.z = nbt_int(root, "zPos", 0) as i32;
    c.data_version = nbt_int(root, "DataVersion", 0) as i32;
    let status = nbt_child(root, "Status");
    if nbt_valid(status) {
        let p = nbt_nodes[status].payload;
        c.status = p;
    }
    c.present = true;
    let sections = nbt_child(root, "sections");
    if nbt_valid(sections) {
        var s = nbt_nodes[sections].first;
        while s >= 0 {
            let y = nbt_int(s, "Y", 0) as i32;
            let idx = y + 4;
            if idx >= 0 && idx < 24 {
                section_from_nbt(s, c.sections[idx]);
                c.sections[idx].y = y;
                if idx < c.section_lo { c.section_lo = idx; }
                if idx > c.section_hi { c.section_hi = idx; }
            }
            s = nbt_nodes[s].next;
        }
    }
}

// --- region files -------------------------------------------------------

struct RegionHeader {
    offset: u32,   // in 4 KiB sectors
    sectors: u8,
}

fn region_location(region: const u8[:], cx: i32, cz: i32) -> RegionHeader {
    let idx = ((cx & 31) + (cz & 31) * 32) * 4;
    if idx + 4 > region.len { return RegionHeader { offset: 0, sectors: 0 }; }
    let v = be_u32(region, idx);
    return RegionHeader { offset: v >> 8, sectors: (v & 0xFF) as u8 };
}

fn region_timestamp(region: const u8[:], cx: i32, cz: i32) -> u32 {
    let idx = 4096 + ((cx & 31) + (cz & 31) * 32) * 4;
    if idx + 4 > region.len { return 0; }
    return be_u32(region, idx);
}

// Extract one chunk's NBT bytes (appending to `out`).
fn region_chunk_nbt(region: const u8[:], cx: i32, cz: i32, out: u8[>..]&) -> bool, u8[>..] {
    var err: u8[>..] = [];
    let h = region_location(region, cx, cz);
    if h.offset == 0 || h.sectors == 0 {
        format(err, "region: chunk ", cx, ",", cz, " is not in this file");
        return false, err;
    }
    let start = (h.offset as i64) * 4096;
    if start + 5 > region.len {
        format(err, "region: chunk ", cx, ",", cz, " starts past the end");
        return false, err;
    }
    let length = be_u32(region, start) as i64;
    let kind = region[start + 4];
    if length <= 1 || start + 4 + length > region.len {
        format(err, "region: chunk ", cx, ",", cz, " has a bad record length ", length);
        return false, err;
    }
    let body = region[start + 5 .. start + 4 + length];
    if kind == 1 || kind == 2 {
        let ok, derr = inflate_zlib(body, out);
        if !ok { return false, derr; }
    } else if kind == 3 {
        for b in body { out.push(b); }
    } else if kind == 4 {
        format(err, "region: LZ4 compression (type 4) is not supported yet");
        return false, err;
    } else {
        format(err, "region: unknown compression type ", kind);
        return false, err;
    }
    return true, err;
}

// --- writing ------------------------------------------------------------

// A valid zlib stream made of stored DEFLATE blocks: no compression, no
// table building, and every inflate implementation accepts it. The real
// server opens regions written this way; a real compressor replaces this
// when chunk sizes make it worth it (see DECISIONS.md).
fn zlib_store(src: const u8[:], out: u8[>..]&) {
    out.push(0x78);
    out.push(0x01);
    var off = 0;
    if src.len == 0 {
        out.push(0x01);
        put_le_u16(out, 0);
        put_le_u16(out, 0xFFFF);
    }
    while off < src.len {
        let n = if src.len - off > 65535 { 65535 } else { src.len - off };
        let last = off + n >= src.len;
        out.push(if last { 1 } else { 0 });
        put_le_u16(out, n as u16);
        put_le_u16(out, (n as u16) ^ 0xFFFF);
        for i in n { out.push(src[off + i]); }
        off += n;
    }
    put_be_u32(out, adler32(src));
}

// Build a region file from a list of chunk payloads. `slots` gives, for each
// chunk, its cx/cz; payloads are NBT bytes. Returns the file bytes.
struct RegionSlot { cx: i32, cz: i32, nbt: Sref }

fn region_write(slots: const RegionSlot[:], payloads: const u8[:], out: u8[>..]&) {
    var offsets: u32[1024] = [0; 1024];
    var counts: u8[1024] = [0; 1024];
    var body: u8[>..] = [];
    // Header is written first, then each record at a sector boundary.
    var total_sectors: i64 = 2;
    for i in slots.len {
        let s = slots[i];
        let nbt_bytes = payloads[s.nbt.off .. s.nbt.off + s.nbt.len];
        var z: u8[>..] = [];
        zlib_store(nbt_bytes, z);
        var record: u8[>..] = [];
        put_be_u32(record, (z.len + 1) as u32);
        record.push(2);  // zlib
        for b in z { record.push(b); }
        let sectors = (record.len + 4095) / 4096;
        let idx = ((s.cx & 31) + (s.cz & 31) * 32);
        offsets[idx] = total_sectors as u32;
        counts[idx] = sectors as u8;
        for b in record { body.push(b); }
        for p in sectors * 4096 - record.len { body.push(0); }
        total_sectors += sectors;
    }
    for i in 1024 {
        if offsets[i] == 0 {
            put_be_u32(out, 0);
        } else {
            put_be_u32(out, (offsets[i] << 8) | (counts[i] as u32));
        }
    }
    // Timestamps: seconds since the epoch, as a 32-bit value per chunk.
    let now = umbra_c_time_seconds();
    for i in 1024 {
        put_be_u32(out, if offsets[i] == 0 { 0 } else { now });
    }
    for b in body { out.push(b); }
}

extern fn umbra_c_time_seconds() -> u32 = "umbra_c_time_seconds";
