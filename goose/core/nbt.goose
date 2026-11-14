// Umbra core: NBT (the named binary tag format the game's level.dat, entity
// data and chunk payloads use), read and write.
//
// A parsed document is a tree of nodes in one grow-only array, names and
// string payloads in a byte arena, and array payloads (byte/int/long arrays)
// in a second arena. Nodes refer to each other by index, so a document is
// position independent and can be rewritten in place.

import std;
import core.mem;

var nbt_nodes: NbtNode[>..] = [];
var nbt_names: u8[>..] = [];
var nbt_payload: u8[>..] = [];
var nbt_root: i64 = -1;
var nbt_err: u8[>..] = [];

struct NbtNode {
    tag: u8,          // 1 byte, 2 short, 3 int, 4 long, 5 float, 6 double,
                      // 7 byte_array, 8 string, 9 list, 10 compound,
                      // 11 int_array, 12 long_array
    name: Sref,
    first: i64,       // first child, or -1
    last: i64,        // last child, or -1, so appends need no walk
    next: i64,        // next sibling, or -1
    ival: i64,
    fval: f64,
    payload: Sref,
    count: i64,       // array length or list length
    elem: u8,         // list element tag
}

fn nbt_reset() {
    nbt_nodes = [];
    nbt_names = [];
    nbt_payload = [];
    nbt_root = -1;
    nbt_err = [];
}

fn nbt_node(i: i64) -> NbtNode& { return nbt_nodes[i] }
fn nbt_valid(i: i64) -> bool { return i >= 0 && i < nbt_nodes.len }

fn nbt_name(i: i64) -> u8[:] {
    if !nbt_valid(i) { return nbt_names[0..0]; }
    let s = nbt_nodes[i].name;
    return nbt_names[s.off .. s.off + s.len];
}

fn nbt_push_name(name: const u8[:]) -> Sref {
    let off = nbt_names.len;
    for c in name { nbt_names.push(c); }
    return Sref { off: off, len: name.len };
}

fn nbt_push_payload(b: const u8[:]) -> Sref {
    let off = nbt_payload.len;
    for c in b { nbt_payload.push(c); }
    return Sref { off: off, len: b.len };
}

fn nbt_add_child(parent: i64, child: i64) {
    if parent < 0 { return; }
    if nbt_nodes[parent].first < 0 {
        nbt_nodes[parent].first = child;
    } else {
        nbt_nodes[nbt_nodes[parent].last].next = child;
    }
    nbt_nodes[parent].last = child;
}

// --- reading ------------------------------------------------------------

struct NbtReader {
    src: const u8[:],
    pos: i64,
    bad: bool,
}

fn nbt_read_string(r: NbtReader&) -> Sref {
    if r.pos + 2 > r.src.len {
        r.bad = true;
        format(nbt_err, "nbt: string length past end at ", r.pos);
        return sref_none();
    }
    let n = be_u16(r.src, r.pos) as i64;
    r.pos += 2;
    if r.pos + n > r.src.len {
        r.bad = true;
        format(nbt_err, "nbt: string of ", n, " bytes past end at ", r.pos);
        return sref_none();
    }
    let s = nbt_push_name(r.src[r.pos .. r.pos + n]);
    r.pos += n;
    return s;
}

recursive fn nbt_parse_payload(r: NbtReader&, tag: u8, name: Sref) -> i64 {
    var slot = nbt_nodes.len;
    nbt_nodes.push(NbtNode { tag: tag, name: name, first: -1, last: -1, next: -1,
                             ival: 0, fval: 0.0, payload: sref_none(), count: 0, elem: 0 });
    if tag == 1 {
        if r.pos + 1 > r.src.len { r.bad = true; format(nbt_err, "nbt: byte past end"); return slot; }
        nbt_nodes[slot].ival = r.src[r.pos] as i8 as i64;
        r.pos += 1;
    } else if tag == 2 {
        if r.pos + 2 > r.src.len { r.bad = true; format(nbt_err, "nbt: short past end"); return slot; }
        nbt_nodes[slot].ival = be_i16(r.src, r.pos) as i64;
        r.pos += 2;
    } else if tag == 3 {
        if r.pos + 4 > r.src.len { r.bad = true; format(nbt_err, "nbt: int past end"); return slot; }
        nbt_nodes[slot].ival = be_i32(r.src, r.pos) as i64;
        r.pos += 4;
    } else if tag == 4 {
        if r.pos + 8 > r.src.len { r.bad = true; format(nbt_err, "nbt: long past end"); return slot; }
        nbt_nodes[slot].ival = be_i64(r.src, r.pos);
        r.pos += 8;
    } else if tag == 5 {
        if r.pos + 4 > r.src.len { r.bad = true; format(nbt_err, "nbt: float past end"); return slot; }
        nbt_nodes[slot].fval = be_f32(r.src, r.pos) as f64;
        r.pos += 4;
    } else if tag == 6 {
        if r.pos + 8 > r.src.len { r.bad = true; format(nbt_err, "nbt: double past end"); return slot; }
        nbt_nodes[slot].fval = be_f64(r.src, r.pos);
        r.pos += 8;
    } else if tag == 7 {
        if r.pos + 4 > r.src.len { r.bad = true; format(nbt_err, "nbt: byte array length past end"); return slot; }
        let n = be_i32(r.src, r.pos) as i64;
        r.pos += 4;
        if n < 0 || r.pos + n > r.src.len { r.bad = true; format(nbt_err, "nbt: byte array past end"); return slot; }
        nbt_nodes[slot].payload = nbt_push_payload(r.src[r.pos .. r.pos + n]);
        nbt_nodes[slot].count = n;
        r.pos += n;
    } else if tag == 8 {
        if r.pos + 2 > r.src.len { r.bad = true; format(nbt_err, "nbt: string length past end"); return slot; }
        let n = be_u16(r.src, r.pos) as i64;
        r.pos += 2;
        if r.pos + n > r.src.len { r.bad = true; format(nbt_err, "nbt: string past end"); return slot; }
        nbt_nodes[slot].payload = nbt_push_payload(r.src[r.pos .. r.pos + n]);
        nbt_nodes[slot].count = n;
        r.pos += n;
    } else if tag == 9 {
        if r.pos + 5 > r.src.len { r.bad = true; format(nbt_err, "nbt: list header past end"); return slot; }
        let elem = r.src[r.pos];
        let n = be_i32(r.src, r.pos + 1) as i64;
        r.pos += 5;
        if n < 0 || n > 1000000 { r.bad = true; format(nbt_err, "nbt: list length ", n, " is not sane"); return slot; }
        nbt_nodes[slot].elem = elem;
        nbt_nodes[slot].count = n;
        for i in n {
            let child = nbt_parse_payload(r, elem, sref_none());
            nbt_add_child(slot, child);
            if r.bad { return slot; }
        }
    } else if tag == 10 {
        while true {
            if r.pos + 1 > r.src.len { r.bad = true; format(nbt_err, "nbt: compound past end"); return slot; }
            let t = r.src[r.pos];
            r.pos += 1;
            if t == 0 { break; }
            if t > 12 { r.bad = true; format(nbt_err, "nbt: unknown tag ", t, " at ", r.pos); return slot; }
            let child_name = nbt_read_string(r);
            if r.bad { return slot; }
            let child = nbt_parse_payload(r, t, child_name);
            nbt_add_child(slot, child);
            if r.bad { return slot; }
        };
        // A compound's count is its number of children, filled in on demand.
    } else if tag == 11 {
        if r.pos + 4 > r.src.len { r.bad = true; format(nbt_err, "nbt: int array length past end"); return slot; }
        let n = be_i32(r.src, r.pos) as i64;
        r.pos += 4;
        if n < 0 || r.pos + n * 4 > r.src.len { r.bad = true; format(nbt_err, "nbt: int array past end"); return slot; }
        nbt_nodes[slot].payload = nbt_push_payload(r.src[r.pos .. r.pos + n * 4]);
        nbt_nodes[slot].count = n;
        r.pos += n * 4;
    } else if tag == 12 {
        if r.pos + 4 > r.src.len { r.bad = true; format(nbt_err, "nbt: long array length past end"); return slot; }
        let n = be_i32(r.src, r.pos) as i64;
        r.pos += 4;
        if n < 0 || r.pos + n * 8 > r.src.len { r.bad = true; format(nbt_err, "nbt: long array past end"); return slot; }
        nbt_nodes[slot].payload = nbt_push_payload(r.src[r.pos .. r.pos + n * 8]);
        nbt_nodes[slot].count = n;
        r.pos += n * 8;
    } else {
        r.bad = true;
        format(nbt_err, "nbt: unknown tag ", tag);
    }
    return slot;
}

// Parse a document. The root is a named compound (the format's rule).
fn nbt_parse(src: const u8[:], err: u8[>..]&) -> i64 {
    nbt_reset();
    var r = NbtReader { src: src, pos: 0, bad: false };
    if src.len == 0 {
        format(nbt_err, "nbt: empty input");
        err.append(nbt_err);
        return -1;
    }
    let tag = src[0];
    r.pos = 1;
    if tag != 10 {
        format(nbt_err, "nbt: root tag is ", tag, ", the format says 10 (compound)");
        err.append(nbt_err);
        return -1;
    }
    let root_name = nbt_read_string(r);
    if r.bad { err.append(nbt_err); return -1; }
    let root = nbt_parse_payload(r, tag, root_name);
    if r.bad { err.append(nbt_err); return -1; }
    nbt_root = root;
    return root;
}

// --- lookups ------------------------------------------------------------

fn nbt_child(parent: i64, name: const u8[:]) -> i64 {
    if !nbt_valid(parent) { return -1; }
    var c = nbt_nodes[parent].first;
    while c >= 0 {
        let n = nbt_name(c);
        if n.len == name.len && eq_bytes(n, name) { return c; }
        c = nbt_nodes[c].next;
    }
    return -1;
}

// A path of names separated by '/', e.g. "Data/Player/Health".
fn nbt_path(parent: i64, path: const u8[:]) -> i64 {
    var cur = parent;
    var start = 0;
    var i = 0;
    while i <= path.len {
        if i == path.len || path[i] == '/' {
            let seg = path[start..i];
            if seg.len > 0 { cur = nbt_child(cur, seg); }
            start = i + 1;
        }
        i += 1;
    }
    return cur;
}

fn nbt_int(parent: i64, name: const u8[:], fallback: i64) -> i64 {
    let c = nbt_child(parent, name);
    if !nbt_valid(c) { return fallback; }
    return nbt_nodes[c].ival;
}

fn nbt_double(parent: i64, name: const u8[:], fallback: f64) -> f64 {
    let c = nbt_child(parent, name);
    if !nbt_valid(c) { return fallback; }
    let t = nbt_nodes[c].tag;
    if t == 5 || t == 6 { return nbt_nodes[c].fval; }
    return nbt_nodes[c].ival as f64;
}

fn nbt_string(parent: i64, name: const u8[:]) -> u8[:] {
    let c = nbt_child(parent, name);
    if !nbt_valid(c) { return nbt_payload[0..0]; }
    let s = nbt_nodes[c].payload;
    if !sref_is_some(s) { return nbt_payload[0..0]; }
    return nbt_payload[s.off .. s.off + s.len];
}

fn nbt_count(parent: i64) -> i64 {
    if !nbt_valid(parent) { return 0; }
    var n = 0;
    var c = nbt_nodes[parent].first;
    while c >= 0 {
        n += 1;
        c = nbt_nodes[c].next;
    }
    return n;
}

// --- writing ------------------------------------------------------------

fn nbt_write_string(out: u8[>..]&, s: const u8[:]) {
    put_be_u16(out, s.len as u16);
    for c in s { out.push(c); }
}

recursive fn nbt_write_payload(out: u8[>..]&, i: i64, with_name: bool) {
    let n = nbt_nodes[i];
    if with_name { nbt_write_string(out, nbt_name(i)); }
    if n.tag == 1 {
        out.push(n.ival as! u8);
    } else if n.tag == 2 {
        put_be_i16(out, n.ival as i16);
    } else if n.tag == 3 {
        put_be_i32(out, n.ival as i32);
    } else if n.tag == 4 {
        put_be_i64(out, n.ival);
    } else if n.tag == 5 {
        put_be_u32(out, f32_bits(n.fval as f32));
    } else if n.tag == 6 {
        put_be_u64(out, f64_bits(n.fval));
    } else if n.tag == 7 || n.tag == 11 || n.tag == 12 {
        put_be_i32(out, n.count as i32);
        let p = n.payload;
        if sref_is_some(p) {
            for k in p.len { out.push(nbt_payload[p.off + k]); }
        }
    } else if n.tag == 8 {
        let p = n.payload;
        if sref_is_some(p) {
            nbt_write_string(out, nbt_payload[p.off .. p.off + p.len]);
        } else {
            nbt_write_string(out, "");
        }
    } else if n.tag == 9 {
        out.push(n.elem);
        put_be_i32(out, n.count as i32);
        var c = n.first;
        while c >= 0 {
            nbt_write_payload(out, c, false);
            c = nbt_nodes[c].next;
        }
    } else if n.tag == 10 {
        var c = n.first;
        while c >= 0 {
            out.push(nbt_nodes[c].tag);
            nbt_write_payload(out, c, true);
            c = nbt_nodes[c].next;
        }
        out.push(0);
    }
}

fn nbt_write(out: u8[>..]&) {
    if !nbt_valid(nbt_root) { return; }
    out.push(10);
    nbt_write_payload(out, nbt_root, true);
}

// Separate bit helpers so the writer needs no C for the common path.
fn f32_bits(v: f32) -> u32 { return umbra_c_bits_of_f32(v); }
fn f64_bits(v: f64) -> u64 { return umbra_c_bits_of_f64(v); }

extern fn umbra_c_bits_of_f32(v: f32) -> u32 = "umbra_c_bits_of_f32";
extern fn umbra_c_bits_of_f64(v: f64) -> u64 = "umbra_c_bits_of_f64";

// The bytes of a string node (e.g. a list element), for tests and callers
// that hold the node index rather than a parent and a name.
fn nbt_bytes_at(i: i64) -> u8[:] {
    if !nbt_valid(i) { return nbt_payload[0..0]; }
    let p = nbt_nodes[i].payload;
    if !sref_is_some(p) { return nbt_payload[0..0]; }
    return nbt_payload[p.off .. p.off + p.len];
}
