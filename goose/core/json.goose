// Umbra core: JSON, the format of the game's blockstate and model files.
//
// Everything the client needs from a jar's model data is JSON: blockstates map
// block states to models, models describe boxes, textures and parents. A parsed
// document is a flat node array plus a byte arena, with members linked by index,
// the same shape as the NBT module: no pointers, no allocation per node, and a
// document that can be thrown away by resetting two arrays.
//
// The parser is deliberately strict. It rejects trailing commas, unquoted keys,
// control characters inside strings, bad escapes, leading zeroes in numbers and
// unterminated containers. A model file that the game would refuse must not be
// silently accepted here.

import std;
import core.mem;

const J_NULL: u8 = 0;
const J_BOOL: u8 = 1;
const J_NUM: u8 = 2;
const J_STR: u8 = 3;
const J_ARR: u8 = 4;
const J_OBJ: u8 = 5;

const J_MAX_DEPTH: i64 = 48;

struct JNode {
    kind: u8,
    ival: i64,      // bool value, or the offset of a string in json_bytes
    slen: i64,      // string length in bytes
    fval: f64,      // number
    is_int: bool,   // the number had no fraction or exponent
    first: i64,     // first child of an array or object, or -1
    last: i64,      // last child, so appends need no walk
    next: i64,      // next sibling, or -1
    key: Sref,      // the member name when this node is a value in an object
}

struct JReader {
    src: const u8[:],
    pos: i64,
    bad: bool,
}

var json_nodes: JNode[>..] = [];
var json_bytes: u8[>..] = [];
var json_err: u8[>..] = [];
var json_root: i64 = -1;

fn json_reset() {
    json_nodes = [];
    json_bytes = [];
    json_err = [];
    json_root = -1;
}

fn json_fail(r: JReader&, msg: const u8[:]) {
    if !r.bad {
        r.bad = true;
        json_err = [];
        format(json_err, "json: ", msg, " at byte ", r.pos);
    }
}

fn json_new(kind: u8, key: Sref) -> i64 {
    let slot = json_nodes.len;
    json_nodes.push(JNode { kind: kind, ival: 0, slen: 0, fval: 0.0, is_int: false,
                            first: -1, last: -1, next: -1, key: key });
    return slot;
}

fn json_append(parent: i64, child: i64) {
    if json_nodes[parent].first < 0 {
        json_nodes[parent].first = child;
    } else {
        json_nodes[json_nodes[parent].last].next = child;
    }
    json_nodes[parent].last = child;
}

fn json_push_byte(b: u8) {
    json_bytes.push(b);
}

// UTF-8 for one code point.
fn json_push_utf8(cp: i64) {
    if cp < 0x80 {
        json_push_byte(cp as u8);
    } else if cp < 0x800 {
        json_push_byte((0xC0 | (cp >> 6)) as u8);
        json_push_byte((0x80 | (cp & 0x3F)) as u8);
    } else if cp < 0x10000 {
        json_push_byte((0xE0 | (cp >> 12)) as u8);
        json_push_byte((0x80 | ((cp >> 6) & 0x3F)) as u8);
        json_push_byte((0x80 | (cp & 0x3F)) as u8);
    } else {
        json_push_byte((0xF0 | (cp >> 18)) as u8);
        json_push_byte((0x80 | ((cp >> 12) & 0x3F)) as u8);
        json_push_byte((0x80 | ((cp >> 6) & 0x3F)) as u8);
        json_push_byte((0x80 | (cp & 0x3F)) as u8);
    }
}

fn json_hex_digit(b: u8) -> i64 {
    if b >= 48 && b <= 57 { return (b - 48) as i64; }
    if b >= 97 && b <= 102 { return (b - 97 + 10) as i64; }
    if b >= 65 && b <= 70 { return (b - 65 + 10) as i64; }
    return -1;
}

fn json_skip_ws(r: JReader&) {
    while r.pos < r.src.len {
        let b = r.src[r.pos];
        if b == 32 || b == 9 || b == 10 || b == 13 {
            r.pos += 1;
        } else {
            return;
        }
    }
}

// Reads the four hex digits of a \u escape. Returns -1 when they are not hex.
fn json_read_u4(r: JReader&) -> i64 {
    if r.pos + 4 > r.src.len { return -1; }
    var v: i64 = 0;
    for i in 4 {
        let d = json_hex_digit(r.src[r.pos + i]);
        if d < 0 { return -1; }
        v = v * 16 + d;
    }
    r.pos += 4;
    return v;
}

// A string literal, into json_bytes; returns the number of bytes it occupies.
fn json_parse_string(r: JReader&) -> i64 {
    // The opening quote has already been consumed.
    var start = json_bytes.len;
    while true {
        if r.pos >= r.src.len {
            json_fail(r, "unterminated string");
            return 0;
        }
        let b = r.src[r.pos];
        r.pos += 1;
        if b == 34 {
            return json_bytes.len - start;
        }
        if b < 32 {
            json_fail(r, "control character in a string");
            return 0;
        }
        if b != 92 {
            json_push_byte(b);
            continue;
        }
        if r.pos >= r.src.len {
            json_fail(r, "unterminated escape");
            return 0;
        }
        let e = r.src[r.pos];
        r.pos += 1;
        if e == 34 { json_push_byte(34); }
        else if e == 92 { json_push_byte(92); }
        else if e == 47 { json_push_byte(47); }
        else if e == 98 { json_push_byte(8); }
        else if e == 102 { json_push_byte(12); }
        else if e == 110 { json_push_byte(10); }
        else if e == 114 { json_push_byte(13); }
        else if e == 116 { json_push_byte(9); }
        else if e == 117 {
            let cp = json_read_u4(r);
            if cp < 0 {
                json_fail(r, "bad \\u escape");
                return 0;
            }
            if cp >= 0xD800 && cp <= 0xDBFF {
                // A high surrogate must be followed by a low one.
                if r.pos + 2 > r.src.len || r.src[r.pos] != 92 || r.src[r.pos + 1] != 117 {
                    json_fail(r, "high surrogate without a low surrogate");
                    return 0;
                }
                r.pos += 2;
                let lo = json_read_u4(r);
                if lo < 0xDC00 || lo > 0xDFFF {
                    json_fail(r, "bad low surrogate");
                    return 0;
                }
                json_push_utf8(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
            } else if cp >= 0xDC00 && cp <= 0xDFFF {
                json_fail(r, "low surrogate without a high surrogate");
                return 0;
            } else {
                json_push_utf8(cp);
            }
        }
        else {
            json_fail(r, "unknown escape");
            return 0;
        }
    }
    return 0;
}

fn json_parse_number(r: JReader&, key: Sref) -> i64 {
    let start = r.pos;
    var is_int = true;
    if r.pos < r.src.len && r.src[r.pos] == 45 { r.pos += 1; }
    // -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    if r.pos >= r.src.len { json_fail(r, "number ends early"); return -1; }
    if r.src[r.pos] == 48 {
        r.pos += 1;
        if r.pos < r.src.len && r.src[r.pos] >= 48 && r.src[r.pos] <= 57 {
            json_fail(r, "leading zero in a number");
            return -1;
        }
    } else if r.src[r.pos] >= 49 && r.src[r.pos] <= 57 {
        while r.pos < r.src.len && r.src[r.pos] >= 48 && r.src[r.pos] <= 57 { r.pos += 1; }
    } else {
        json_fail(r, "not a number");
        return -1;
    }
    if r.pos < r.src.len && r.src[r.pos] == 46 {
        is_int = false;
        r.pos += 1;
        if r.pos >= r.src.len || r.src[r.pos] < 48 || r.src[r.pos] > 57 {
            json_fail(r, "fraction with no digits");
            return -1;
        }
        while r.pos < r.src.len && r.src[r.pos] >= 48 && r.src[r.pos] <= 57 { r.pos += 1; }
    }
    if r.pos < r.src.len && (r.src[r.pos] == 101 || r.src[r.pos] == 69) {
        is_int = false;
        r.pos += 1;
        if r.pos < r.src.len && (r.src[r.pos] == 43 || r.src[r.pos] == 45) { r.pos += 1; }
        if r.pos >= r.src.len || r.src[r.pos] < 48 || r.src[r.pos] > 57 {
            json_fail(r, "exponent with no digits");
            return -1;
        }
        while r.pos < r.src.len && r.src[r.pos] >= 48 && r.src[r.pos] <= 57 { r.pos += 1; }
    }
    let slot = json_new(J_NUM, key);
    json_nodes[slot].fval = json_to_f64(r.src[start .. r.pos]);
    json_nodes[slot].is_int = is_int;
    if is_int {
        // Integers are consumed with the same parser, so `is_int` is the only
        // promise made about the value's shape.
        json_nodes[slot].ival = json_to_i64(r.src[start .. r.pos]);
    }
    return slot;
}

// Text to f64, without a libc strtod: sign, integer part, fraction, exponent.
fn json_to_f64(s: const u8[:]) -> f64 {
    var i: i64 = 0;
    var neg = false;
    if i < s.len && s[i] == 45 { neg = true; i += 1; }
    var v: f64 = 0.0;
    while i < s.len && s[i] >= 48 && s[i] <= 57 {
        v = v * 10.0 + ((s[i] - 48) as f64);
        i += 1;
    }
    if i < s.len && s[i] == 46 {
        i += 1;
        var scale: f64 = 0.1;
        while i < s.len && s[i] >= 48 && s[i] <= 57 {
            v += ((s[i] - 48) as f64) * scale;
            scale *= 0.1;
            i += 1;
        }
    }
    if i < s.len && (s[i] == 101 || s[i] == 69) {
        i += 1;
        var eneg = false;
        if i < s.len && (s[i] == 43 || s[i] == 45) {
            eneg = s[i] == 45;
            i += 1;
        }
        var e: i64 = 0;
        while i < s.len && s[i] >= 48 && s[i] <= 57 {
            e = e * 10 + (s[i] - 48) as i64;
            i += 1;
        }
        var m: f64 = 1.0;
        for k in e { m *= 10.0; }
        if eneg { v /= m; } else { v *= m; }
    }
    return if neg { 0.0 - v } else { v };
}

fn json_to_i64(s: const u8[:]) -> i64 {
    var i: i64 = 0;
    var neg = false;
    if i < s.len && s[i] == 45 { neg = true; i += 1; }
    var v: i64 = 0;
    while i < s.len && s[i] >= 48 && s[i] <= 57 {
        v = v * 10 + (s[i] - 48) as i64;
        i += 1;
    }
    return if neg { -v } else { v };
}

recursive fn json_parse_value(r: JReader&, depth: i64, key: Sref) -> i64 {
    if r.bad { return -1; }
    if depth > J_MAX_DEPTH {
        json_fail(r, "nested too deeply");
        return -1;
    }
    json_skip_ws(r);
    if r.pos >= r.src.len {
        json_fail(r, "value expected, input ended");
        return -1;
    }
    let b = r.src[r.pos];
    if b == 123 { return json_parse_object(r, depth, key); }
    if b == 91 { return json_parse_array(r, depth, key); }
    if b == 34 {
        r.pos += 1;
        let n = json_parse_string(r);
        if r.bad { return -1; }
        let slot = json_new(J_STR, key);
        json_nodes[slot].ival = json_bytes.len - n;
        json_nodes[slot].slen = n;
        return slot;
    }
    if b == 116 {
        if !json_literal(r, "true") { return -1; }
        let slot = json_new(J_BOOL, key);
        json_nodes[slot].ival = 1;
        return slot;
    }
    if b == 102 {
        if !json_literal(r, "false") { return -1; }
        return json_new(J_BOOL, key);
    }
    if b == 110 {
        if !json_literal(r, "null") { return -1; }
        return json_new(J_NULL, key);
    }
    if b == 45 || (b >= 48 && b <= 57) { return json_parse_number(r, key); }
    json_fail(r, "unexpected character where a value belongs");
    return -1;
}

fn json_literal(r: JReader&, word: const u8[:]) -> bool {
    if r.pos + word.len > r.src.len {
        json_fail(r, "literal past end");
        return false;
    }
    for i in word.len {
        if r.src[r.pos + i] != word[i] {
            json_fail(r, "bad literal");
            return false;
        }
    }
    r.pos += word.len;
    return true;
}

recursive fn json_parse_object(r: JReader&, depth: i64, key: Sref) -> i64 {
    let slot = json_new(J_OBJ, key);
    r.pos += 1;  // the '{'
    json_skip_ws(r);
    if r.pos < r.src.len && r.src[r.pos] == 125 {
        r.pos += 1;
        return slot;
    }
    while true {
        json_skip_ws(r);
        if r.pos >= r.src.len || r.src[r.pos] != 34 {
            json_fail(r, "member name expected");
            return slot;
        }
        r.pos += 1;
        let name_len = json_parse_string(r);
        if r.bad { return slot; }
        let name = sref_of(json_bytes, json_bytes.len - name_len, name_len);
        json_skip_ws(r);
        if r.pos >= r.src.len || r.src[r.pos] != 58 {
            json_fail(r, "':' expected after a member name");
            return slot;
        }
        r.pos += 1;
        let child = json_parse_value(r, depth + 1, name);
        if r.bad { return slot; }
        json_append(slot, child);
        json_skip_ws(r);
        if r.pos >= r.src.len {
            json_fail(r, "unterminated object");
            return slot;
        }
        if r.src[r.pos] == 44 {
            r.pos += 1;
            // A trailing comma is an error, not something to forgive.
            json_skip_ws(r);
            if r.pos < r.src.len && r.src[r.pos] == 125 {
                json_fail(r, "trailing comma in an object");
                return slot;
            }
            continue;
        }
        if r.src[r.pos] == 125 {
            r.pos += 1;
            return slot;
        }
        json_fail(r, "',' or '}' expected in an object");
        return slot;
    }
    return slot;
}

recursive fn json_parse_array(r: JReader&, depth: i64, key: Sref) -> i64 {
    let slot = json_new(J_ARR, key);
    r.pos += 1;  // the '['
    json_skip_ws(r);
    if r.pos < r.src.len && r.src[r.pos] == 93 {
        r.pos += 1;
        return slot;
    }
    while true {
        let child = json_parse_value(r, depth + 1, sref_none());
        if r.bad { return slot; }
        json_append(slot, child);
        json_skip_ws(r);
        if r.pos >= r.src.len {
            json_fail(r, "unterminated array");
            return slot;
        }
        if r.src[r.pos] == 44 {
            r.pos += 1;
            json_skip_ws(r);
            if r.pos < r.src.len && r.src[r.pos] == 93 {
                json_fail(r, "trailing comma in an array");
                return slot;
            }
            continue;
        }
        if r.src[r.pos] == 93 {
            r.pos += 1;
            return slot;
        }
        json_fail(r, "',' or ']' expected in an array");
        return slot;
    }
    return slot;
}

// Parses a whole document. Returns the root node, or -1 on error, with the
// reason in json_err. Trailing bytes after the root value are an error: a model
// file is one value, and half-parsed data is worse than none.
fn json_parse(src: const u8[:]) -> i64 {
    json_reset();
    var r = JReader { src: src, pos: 0, bad: false };
    let root = json_parse_value(r, 0, sref_none());
    if r.bad {
        json_root = -1;
        return -1;
    }
    json_skip_ws(r);
    if r.pos != src.len {
        json_fail(r, "trailing bytes after the document");
        json_root = -1;
        return -1;
    }
    json_root = root;
    return root;
}

fn json_error() -> const u8[:] { return json_err[..] }

// --- accessors ----------------------------------------------------------

fn json_valid(i: i64) -> bool { return i >= 0 && i < json_nodes.len }
fn json_kind(i: i64) -> u8 { return if json_valid(i) { json_nodes[i].kind } else { J_NULL } }

fn json_str(i: i64) -> const u8[:] {
    if json_kind(i) != J_STR { return json_bytes[0..0]; }
    let n = json_nodes[i];
    return json_bytes[n.ival .. n.ival + n.slen];
}

fn json_num(i: i64) -> f64 {
    if json_kind(i) != J_NUM { return 0.0; }
    return json_nodes[i].fval;
}

fn json_int(i: i64) -> i64 {
    if json_kind(i) != J_NUM { return 0; }
    return json_nodes[i].ival;
}

fn json_bool(i: i64) -> bool { return json_kind(i) == J_BOOL && json_nodes[i].ival != 0 }
fn json_is(i: i64, kind: u8) -> bool { return json_kind(i) == kind }

fn json_key(i: i64) -> const u8[:] {
    if !json_valid(i) { return json_bytes[0..0]; }
    let k = json_nodes[i].key;
    if k.off < 0 { return json_bytes[0..0]; }
    return json_bytes[k.off .. k.off + k.len];
}

fn json_child_count(i: i64) -> i64 {
    if !json_valid(i) { return 0; }
    var n: i64 = 0;
    var c = json_nodes[i].first;
    while c >= 0 {
        n += 1;
        c = json_nodes[c].next;
    }
    return n;
}

// The k-th child of an array or object, or -1.
fn json_at(i: i64, k: i64) -> i64 {
    if !json_valid(i) { return -1; }
    var c = json_nodes[i].first;
    var n: i64 = 0;
    while c >= 0 {
        if n == k { return c; }
        n += 1;
        c = json_nodes[c].next;
    }
    return -1;
}

fn json_byte_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len {
        if a[i] != b[i] { return false; }
    }
    return true;
}

// The value of a member of an object, or -1. A later duplicate wins, which is
// what the game's own reader does.
fn json_get(obj: i64, name: const u8[:]) -> i64 {
    if json_kind(obj) != J_OBJ { return -1; }
    var found: i64 = -1;
    var c = json_nodes[obj].first;
    while c >= 0 {
        let k = json_nodes[c].key;
        if k.off >= 0 && k.len == name.len {
            if json_byte_eq(json_bytes[k.off .. k.off + k.len], name) { found = c; }
        }
        c = json_nodes[c].next;
    }
    return found;
}

// The string value of a member, or an empty slice when it is absent or not a
// string. Callers that must tell "absent" from "empty" ask json_get first.
fn json_get_str(obj: i64, name: const u8[:]) -> const u8[:] {
    return json_str(json_get(obj, name));
}

fn json_get_int(obj: i64, name: const u8[:]) -> i64 {
    return json_int(json_get(obj, name));
}

fn json_get_bool(obj: i64, name: const u8[:]) -> bool {
    return json_bool(json_get(obj, name));
}
