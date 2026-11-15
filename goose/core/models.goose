// Umbra core: block models, the way the jar describes them.
//
// A block model is JSON with `elements` (boxes) and, per element, up to six
// `faces`. Each face names a texture variable, optionally an explicit `uv` rect in
// the model's own 0..16 space, a `cullface` (the neighbour that makes this face
// invisible), a `tintindex` (which biome/tint layer multiplies it), and a `rotation`
// of its texture in 90 degree steps. A model may `parent` another and inherit its
// elements and textures; a child's texture entries override the parent's.
//
// This module parses one resolved model - the chain is walked by the caller, which
// is also who knows how to load the parent's bytes - into flat arenas, and turns an
// element into quads in block space with the UV rect mapped into an atlas tile.
//
// Why flat arenas and not a tree of structs: the mesher asks for quads block by
// block, thousands of times a second on a phone, and a struct per face would be an
// allocation or a fixed cap. Indexes into parallel arrays do not allocate and do
// not cap.

import std;
import core.mem;
import core.json;

// Face order matches the mesher's: 0 -Y, 1 +Y, 2 -Z, 3 +Z, 4 -X, 5 +X. The jar's
// names for those are `down`, `up`, `north`, `south`, `west`, `east` in the same
// order; the mapping is a function rather than a table because Goose arrays of
// fixed-size arrays cannot be indexed.
fn mdl_face_name(face: i64) -> const u8[:] {
    if face == 0 { return "down"; }
    if face == 1 { return "up"; }
    if face == 2 { return "north"; }
    if face == 3 { return "south"; }
    if face == 4 { return "west"; }
    return "east";
}

// Per element, three floats each.
var mdl_from: f32[>..] = [];
var mdl_to: f32[>..] = [];
// Per element and face: a texture slot (-1 when the face is absent), a UV rect in
// 0..16 model space, a cullface (-1 or a face index), a tint index (-1 or 0..n)
// and a texture rotation in 90 degree steps.
var mdl_tex: i64[>..] = [];
var mdl_uv: f32[>..] = [];
var mdl_cull: i64[>..] = [];
var mdl_tint: i64[>..] = [];
var mdl_rot: i64[>..] = [];
// The resolved `textures` map: a byte pool with offset/length pairs, because an
// array of variable-size arrays cannot be indexed in Goose (and an atlas texturing
// every block face wants random access).
var mdl_pool: u8[>..] = [];
var mdl_tkey_off: i64[>..] = [];
var mdl_tkey_len: i64[>..] = [];
var mdl_tval_off: i64[>..] = [];
var mdl_tval_len: i64[>..] = [];
var mdl_par_off: i64 = -1;
var mdl_par_len: i64 = 0;
var mdl_elements: i64 = 0;
var mdl_error: u8[>..] = [];

fn mdl_reset() {
    mdl_from = [];
    mdl_to = [];
    mdl_tex = [];
    mdl_uv = [];
    mdl_cull = [];
    mdl_tint = [];
    mdl_rot = [];
    mdl_pool = [];
    mdl_tkey_off = [];
    mdl_tkey_len = [];
    mdl_tval_off = [];
    mdl_tval_len = [];
    mdl_par_off = -1;
    mdl_par_len = 0;
    mdl_elements = 0;
    mdl_error = [];
}

// Copies a name into the pool and returns its key index.
fn mdl_pool_put(name: const u8[:]) -> i64 {
    let off = mdl_pool.len;
    for b in name { mdl_pool.push(b); }
    return off;
}

fn mdl_key_len() -> i64 { return mdl_tkey_off.len; }
fn mdl_key(i: i64) -> const u8[:] {
    return mdl_pool[mdl_tkey_off[i] .. mdl_tkey_off[i] + mdl_tkey_len[i]]
}
fn mdl_val(i: i64) -> const u8[:] {
    return mdl_pool[mdl_tval_off[i] .. mdl_tval_off[i] + mdl_tval_len[i]]
}
fn mdl_parent_name() -> const u8[:] {
    if mdl_par_off < 0 { return ""; }
    return mdl_pool[mdl_par_off .. mdl_par_off + mdl_par_len];
}

fn mdl_fail(msg: const u8[:]) {
    mdl_error = [];
    format(mdl_error, msg);
}

// `#name` chains: a texture entry may point at another entry. This walks up to
// eight hops, which is more than any jar model does, and refuses a cycle.
fn mdl_resolve_texture(name: const u8[:]) -> u8[>..] {
    var cur: u8[>..] = [];
    for b in name { cur.push(b); }
    var hops = 0;
    while hops < 8 && cur.len > 1 && cur[0] == '#' {
        let key = cur[1..];
        var next: i64 = -1;
        for i in mdl_key_len() {
            if eq_bytes(mdl_key(i), key) { next = i; }
        }
        if next < 0 { break; }
        cur = [];
        let v = mdl_val(next);
        for b in v { cur.push(b); }
        hops += 1;
    }
    return cur;
}

fn mdl_texture_index(name: const u8[:]) -> i64 {
    // A face's texture is resolved through the `#` chain and then interned into
    // this model's slot list by first appearance. The caller's atlas asks for the
    // same names in the same order, so slot n here is tile n there.
    let resolved = mdl_resolve_texture(name);
    if resolved.len == 0 { return -1; }
    for i in mdl_key_len() {
        if eq_bytes(mdl_resolve_texture(mdl_key(i)), resolved) { return i; }
    }
    let koff = mdl_pool_put(resolved);
    let v = copy(resolved);
    let voff = mdl_pool_put(v);
    mdl_tkey_off.push(koff);
    mdl_tkey_len.push(resolved.len);
    mdl_tval_off.push(voff);
    mdl_tval_len.push(v.len);
    return mdl_key_len() - 1;
}

fn mdl_face_name_index(name: const u8[:]) -> i64 {
    for f in 6 {
        if eq_bytes(name, mdl_face_name(f)) { return f; }
    }
    return -1;
}

// The default UV rect of a face: the whole tile. A model that names a sub-rect
// (a slab's side, a torch) overrides this.
fn mdl_default_uv(face: i64) -> f32[4] {
    return [0.0, 0.0, 16.0, 16.0];
}

fn mdl_clamp01(v: f64) -> f64 {
    if v < 0.0 { return 0.0; }
    if v > 1.0 { return 1.0; }
    return v;
}

// Parses one resolved model document. Returns the number of elements, or -1 with
// mdl_error set. `textures` already merged by the caller is *not* expected: this
// reads the model's own `textures` block, and the caller merges its parents by
// calling mdl_parse on each link child-first (a child's entry replaces the parent's
// because it is parsed first and mdl_texture_index keeps the first appearance).
fn mdl_parse(src: const u8[:]) -> i64 {
    let root = json_parse(src);
    if root < 0 || json_kind(root) != J_OBJ {
        mdl_fail("model: not a JSON object");
        return -1;
    }
    let parent = json_get(root, "parent");
    if parent >= 0 {
        let ps = json_str(parent);
        mdl_par_off = mdl_pool_put(ps);
        mdl_par_len = ps.len;
    }
    let textures = json_get(root, "textures");
    if textures >= 0 && json_kind(textures) == J_OBJ {
        var c = json_first(textures);
        while c >= 0 {
            let k = json_key(c);
            let v = json_str(c);
            if v.len > 0 {
                let koff = mdl_pool_put(k);
                let voff = mdl_pool_put(v);
                mdl_tkey_off.push(koff);
                mdl_tkey_len.push(k.len);
                mdl_tval_off.push(voff);
                mdl_tval_len.push(v.len);
            }
            c = json_next(c);
        }
    }
    let elements = json_get(root, "elements");
    if elements < 0 { return mdl_elements; }        // a template: geometry comes from a parent
    if json_kind(elements) != J_ARR {
        mdl_fail("model: elements is not an array");
        return -1;
    }
    var e = json_first(elements);
    while e >= 0 {
        let from = json_get(e, "from");
        let to = json_get(e, "to");
        if from < 0 || to < 0 || json_kind(from) != J_ARR || json_kind(to) != J_ARR ||
           json_child_count(from) < 3 || json_child_count(to) < 3 {
            mdl_fail("model: element without from/to");
            return -1;
        }
        mdl_from.push(json_num(json_at(from, 0)) as f32);
        mdl_from.push(json_num(json_at(from, 1)) as f32);
        mdl_from.push(json_num(json_at(from, 2)) as f32);
        mdl_to.push(json_num(json_at(to, 0)) as f32);
        mdl_to.push(json_num(json_at(to, 1)) as f32);
        mdl_to.push(json_num(json_at(to, 2)) as f32);
        let base = mdl_tex.len;
        for f in 6 {
            mdl_tex.push(-1);
            for k in 4 { mdl_uv.push(0.0); }
            mdl_cull.push(-1);
            mdl_tint.push(-1);
            mdl_rot.push(0);
        }
        let faces = json_get(e, "faces");
        if faces >= 0 && json_kind(faces) == J_OBJ {
            var c = json_first(faces);
            while c >= 0 {
                let fname = json_key(c);
                let f = mdl_face_name_index(fname);
                if f >= 0 {
                    let fi = base + f;
                    let tex = json_get_str(c, "texture");
                    if tex.len > 0 { mdl_tex[fi] = mdl_texture_index(tex); }
                    let uv = json_get(c, "uv");
                    if uv >= 0 && json_kind(uv) == J_ARR && json_child_count(uv) == 4 {
                        for k in 4 {
                            mdl_uv[fi * 4 + k] = json_num(json_at(uv, k)) as f32;
                        }
                    } else {
                        let d = mdl_default_uv(f);
                        for k in 4 { mdl_uv[fi * 4 + k] = d[k]; }
                    }
                    let cf = json_get_str(c, "cullface");
                    if cf.len > 0 { mdl_cull[fi] = mdl_face_name_index(cf); }
                    let ti = json_get(c, "tintindex");
                    if ti >= 0 { mdl_tint[fi] = json_int(ti); }
                    let rot = json_get(c, "rotation");
                    if rot >= 0 { mdl_rot[fi] = json_int(rot) / 90; }
                }
                c = json_next(c);
            }
        }
        mdl_elements += 1;
        e = json_next(e);
    }
    return mdl_elements;
}

// How many faces the parsed model actually draws.
fn mdl_face_count() -> i64 {
    var n: i64 = 0;
    for i in mdl_tex.len {
        if mdl_tex[i] >= 0 { n += 1; }
    }
    return n;
}

// The atlas rect of a face, given the atlas rect of its texture tile. `uv` is in
// the model's 0..16 space and may be reversed (a mirrored face), which a model is
// allowed to ask for.
fn mdl_face_uv(elem: i64, face: i64, tile_u0: f32, tile_v0: f32, tile_u1: f32, tile_v1: f32,
               out: f32[4]&) {
    let fi = elem * 6 + face;
    let tw = tile_u1 - tile_u0;
    let th = tile_v1 - tile_v0;
    var u0 = mdl_uv[fi * 4 + 0] / 16.0;
    var v0 = mdl_uv[fi * 4 + 1] / 16.0;
    var u1 = mdl_uv[fi * 4 + 2] / 16.0;
    var v1 = mdl_uv[fi * 4 + 3] / 16.0;
    // The jar's uv y axis runs down from the top of the tile; the atlas v axis
    // runs down from the top of the image too (v0 is the tile's top row), so the
    // rect maps directly.
    let r = mdl_rot[fi] % 4;
    var a0 = u0;
    var b0 = v0;
    var a1 = u1;
    var b1 = v1;
    if r == 1 { a0 = u1; b0 = v0; a1 = u0; b1 = v1; }
    else if r == 2 { a0 = u1; b0 = v1; a1 = u0; b1 = v0; }
    else if r == 3 { a0 = u0; b0 = v1; a1 = u1; b1 = v0; }
    out[0] = tile_u0 + a0 * tw;
    out[1] = tile_v0 + b0 * th;
    out[2] = tile_u0 + a1 * tw;
    out[3] = tile_v0 + b1 * th;
}

// Is this face's box side on the surface of the block, so that a solid neighbour
// on that side hides it entirely? Only then may the mesher drop it, and only when
// the model said so with `cullface`.
fn mdl_face_cullable(elem: i64, face: i64) -> bool {
    let want = mdl_cull[elem * 6 + face];
    if want < 0 || want != face { return false; }
    let lo = mdl_from[elem * 3 + axis_of(face)];
    let hi = mdl_to[elem * 3 + axis_of(face)];
    let positive = face == 1 || face == 3 || face == 5;
    if positive { return hi >= 15.9; }
    return lo <= 0.1;
}

fn axis_of(face: i64) -> i64 { return face / 2; }

// The box of one element in block space, 0..1.
fn mdl_elem_box(elem: i64, lo: f32[3]&, hi: f32[3]&) {
    for a in 3 {
        lo[a] = mdl_from[elem * 3 + a] / 16.0;
        hi[a] = mdl_to[elem * 3 + a] / 16.0;
    }
}

// The resolved texture path of a slot: `#` chains walked to the end, so a face
// that says `#top` and an entry `top: "#bottom"` both come back as
// `block/oak_planks`.
var mdl_resolved: u8[>..] = [];

fn mdl_texture_name(face_index: i64) -> const u8[:] {
    if face_index < 0 || face_index >= mdl_key_len() { return "" }
    mdl_resolved = mdl_resolve_texture(mdl_val(face_index));
    return mdl_resolved
}

fn mdl_error_text() -> const u8[:] { return mdl_error }

// Counts for the log: how much geometry a model describes.
struct ModelStats {
    elements: i64,
    faces: i64,
    with_uv: i64,
    with_cull: i64,
    with_tint: i64,
    rotated: i64,
}

fn mdl_stats() -> ModelStats {
    var s = ModelStats { elements: mdl_elements, faces: 0, with_uv: 0, with_cull: 0,
                         with_tint: 0, rotated: 0 };
    for i in mdl_tex.len {
        if mdl_tex[i] < 0 { continue; }
        s.faces += 1;
        if mdl_uv[i * 4 + 0] != 0.0 || mdl_uv[i * 4 + 1] != 0.0 ||
           mdl_uv[i * 4 + 2] != 16.0 || mdl_uv[i * 4 + 3] != 16.0 {
            s.with_uv += 1;
        }
        if mdl_cull[i] >= 0 { s.with_cull += 1; }
        if mdl_tint[i] >= 0 { s.with_tint += 1; }
        if mdl_rot[i] % 4 != 0 { s.rotated += 1; }
    }
    return s;
}
