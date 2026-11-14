// Umbra core: byte-level helpers shared by every format reader.
// All of this is game logic and lives in Goose. No heap: callers own their
// grow arrays, and every function here writes into a caller destination or
// reads from a slice.

import std;

// A view of bytes inside one of the program's arenas: an offset and a
// length. Offsets, not pointers, so an arena may regrow under a view.
struct Sref { off: i64, len: i64 }

fn sref_none() -> Sref { Sref { off: -1, len: 0 } }
fn sref_is_some(s: Sref) -> bool { s.off >= 0 }
fn sref_of(a: const u8[:], off: i64, len: i64) -> Sref {
    return Sref { off: off, len: len };
}
// The bytes a view names, in the arena it came from.
fn sref_bytes(a: u8[:], s: Sref) -> u8[:] {
    if !sref_is_some(s) { return a[0..0]; }
    return a[s.off .. s.off + s.len];
}

// --- big-endian scalar reads (NBT, chunk formats) -----------------------

fn be_u16(b: const u8[:], off: i64) -> u16 {
    return (b[off] as u16 << 8) | (b[off + 1] as u16);
}
fn be_u32(b: const u8[:], off: i64) -> u32 {
    return (be_u16(b, off) as u32 << 16) | (be_u16(b, off + 2) as u32);
}
fn be_u64(b: const u8[:], off: i64) -> u64 {
    return (be_u32(b, off) as u64 << 32) | (be_u32(b, off + 4) as u64);
}
fn be_i16(b: const u8[:], off: i64) -> i16 { return be_u16(b, off) as i16; }
fn be_i32(b: const u8[:], off: i64) -> i32 { return be_u32(b, off) as i32; }
fn be_i64(b: const u8[:], off: i64) -> i64 { return be_u64(b, off) as i64; }
fn be_f32(b: const u8[:], off: i64) -> f32 {
    return f32_from_bits(be_u32(b, off));
}
fn be_f64(b: const u8[:], off: i64) -> f64 {
    return f64_from_bits(be_u64(b, off));
}

// --- little-endian scalar reads/writes (PNG, region headers) ------------

fn le_u32(b: const u8[:], off: i64) -> u32 {
    return (b[off] as u32) | (b[off + 1] as u32 << 8) | (b[off + 2] as u32 << 16) |
           (b[off + 3] as u32 << 24);
}
fn le_i32(b: const u8[:], off: i64) -> i32 { return le_u32(b, off) as i32; }
fn le_u16(b: const u8[:], off: i64) -> u16 {
    return (b[off] as u16) | (b[off + 1] as u16 << 8);
}

fn put_le_u32(out: u8[>..]&, v: u32) {
    out.push((v & 0xFF) as u8);
    out.push(((v >> 8) & 0xFF) as u8);
    out.push(((v >> 16) & 0xFF) as u8);
    out.push(((v >> 24) & 0xFF) as u8);
}
fn put_le_u16(out: u8[>..]&, v: u16) {
    out.push((v & 0xFF) as u8);
    out.push(((v >> 8) & 0xFF) as u8);
}
fn put_be_u16(out: u8[>..]&, v: u16) {
    out.push(((v >> 8) & 0xFF) as u8);
    out.push((v & 0xFF) as u8);
}
fn put_be_u32(out: u8[>..]&, v: u32) {
    out.push(((v >> 24) & 0xFF) as u8);
    out.push(((v >> 16) & 0xFF) as u8);
    out.push(((v >> 8) & 0xFF) as u8);
    out.push((v & 0xFF) as u8);
}
fn put_be_i16(out: u8[>..]&, v: i16) { put_be_u16(out, v as! u16); }
fn put_be_i32(out: u8[>..]&, v: i32) { put_be_u32(out, v as! u32); }
fn put_be_u64(out: u8[>..]&, v: u64) {
    put_be_u32(out, (v >> 32) as u32);
    put_be_u32(out, (v & 0xFFFFFFFF) as u32);
}
fn put_be_i64(out: u8[>..]&, v: i64) { put_be_u64(out, v as! u64); }

// --- 32-bit float bit casts (used by model parsing and the mesher) ------

// Provided by the C platform layer (platform/shared/umbra_glue.c).
extern fn umbra_c_f32_from_bits(bits: u32) -> f32 = "umbra_c_f32_from_bits";
extern fn umbra_c_f64_from_bits(bits: u64) -> f64 = "umbra_c_f64_from_bits";

fn f32_from_bits(bits: u32) -> f32 { return umbra_c_f32_from_bits(bits); }
fn f64_from_bits(bits: u64) -> f64 { return umbra_c_f64_from_bits(bits); }

// --- checksums ----------------------------------------------------------

// CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) as zip and PNG use it.
var crc_table: u32[256] = [0; 256];
var crc_ready = false;

fn crc32_init() {
    if crc_ready { return; }
    for n in 256 {
        var c: u32 = n as u32;
        for k in 8 {
            if (c & 1) != 0 { c = 0xEDB88320 ^ (c >> 1); } else { c = c >> 1; }
        }
        crc_table[n] = c;
    }
    crc_ready = true;
}

fn crc32(data: const u8[:]) -> u32 {
    var c: u32 = 0xFFFFFFFF;
    for b in data {
        c = crc_table[(c ^ (b as u32)) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

// Adler-32 as zlib streams use it.
fn adler32(data: const u8[:]) -> u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for x in data {
        a = (a + (x as u32)) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

// --- LEB128 (Anvil paletted containers) ---------------------------------

struct Leb { v: u32, n: i64 }

fn read_leb(b: const u8[:], off: i64) -> Leb {
    var v: u32 = 0;
    var shift = 0;
    var i = off;
    while i < b.len {
        let byte = b[i];
        v |= ((byte & 0x7F) as u32) << shift;
        i += 1;
        if (byte & 0x80) == 0 { break; }
        shift += 7;
        if shift >= 35 { break; }
    }
    return Leb { v: v, n: i - off };
}

fn put_leb(out: u8[>..]&, value: u32) {
    var v = value;
    while true {
        var byte = (v & 0x7F) as u8;
        v = v >> 7;
        if v != 0 { byte = byte | 0x80; }
        out.push(byte);
        if v == 0 { break; }
    }
}

// --- misc ---------------------------------------------------------------

fn u64_slice_to_array(b: const u8[:], off: i64, count: i64, out: i64[]) {
    for i in count {
        out[i] = be_i64(b, off + i * 8);
    }
}

fn eq_bytes(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len {
        if a[i] != b[i] { return false; }
    }
    return true;
}

fn u64_to_hex(v: u64, digits: i64) -> u8[>..] {
    var out: u8[>..] = [];
    let hex = "0123456789abcdef";
    var i = digits;
    while i > 0 {
        i -= 1;
        let nib = ((v >> (i * 4)) & 0xF) as u8;
        out.push(hex[nib]);
    }
    return out;
}
