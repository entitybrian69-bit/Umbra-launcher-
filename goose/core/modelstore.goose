// Umbra core: every block model in the jar, and the blockstates that point at them.
//
// The first cut parsed one model at a time and bound it to one block (D-040). That
// was enough to prove the geometry path and useless for a real world, where every
// block has its own model and a blockstate decides which one (and at what rotation)
// a given state uses. This module is the replacement: a flat store of models and
// blockstate rules, addressed by index, with no cap on how many.
//
// Shape of the store
// ------------------
// * Models are appended to parallel arenas; a model is a range of *faces*. A face
//   remembers which of the six sides it is, the element box it came from (0..16),
//   its uv rect in model space, the texture *path* it resolved to, its cullface,
//   tint index, uv rotation and shade flag. Elements are stored too, because a
//   blockstate's cullface rule asks "is the neighbour a full cube".
// * Texture paths are interned into one table for the whole store, so the atlas can
//   be built by walking that table once.
// * A blockstate is a name plus a list of rules. A rule is a model, an x rotation, a
//   y rotation, a uvlock flag, a weight, and (for `multipart`) a condition made of
//   `property in {values}` clauses. `variants` rules have no condition: their key is
//   the property string itself, and a rule matches when every `k=v` in that key is
//   true of the block.
//
// Why flat arenas again: the mesher asks for the models of a block tens of thousands
// of times while meshing a world, and a structure per model would be an allocation
// per block. Indexes into arrays do not allocate.

import std;
import core.mem;
import core.json;

// --- texture paths -------------------------------------------------------

var mts_pool: u8[>..] = [];
var mts_off: i64[>..] = [];
var mts_len: i64[>..] = [];

fn ms_path_count() -> i64 { return mts_off.len; }

fn ms_path(i: i64) -> const u8[:] {
    if i < 0 || i >= mts_off.len { return ""; }
    return mts_pool[mts_off[i] .. mts_off[i] + mts_len[i]]
}

fn ms_path_intern(path: const u8[:]) -> i64 {
    for i in mts_off.len {
        if eq_bytes(ms_path(i), path) { return i; }
    }
    let off = mts_pool.len;
    for b in path { mts_pool.push(b); }
    mts_off.push(off);
    mts_len.push(path.len as i64);
    return mts_off.len - 1;
}

// --- models --------------------------------------------------------------

struct ModelRec {
    name_off: i64,
    name_len: i64,
    face_start: i64,
    face_count: i64,
    elem_start: i64,
    elem_count: i64,
    full: bool,        // one element filling 0..16 with all six faces
    has_any: bool,
}

var mts_models: ModelRec[>..] = [];
var mts_names: u8[>..] = [];

// Per face.
var msf_side: i64[>..] = [];     // 0..5, the mesher's order
var msf_elem: i64[>..] = [];     // index into the element table
var msf_face: i64[>..] = [];     // jar face index for uv rotation: 0 down,1 up,2 north...
var msf_uv: f32[>..] = [];       // 4 per face, 0..16
var msf_tex: i64[>..] = [];      // texture path index, -1 when the face has no texture
var msf_cull: i64[>..] = [];     // -1, or the mesher face index it can be culled against
var msf_tint: i64[>..] = [];     // -1, or 0..2
var msf_rot: i64[>..] = [];      // 0..3 quarter turns
var msf_shade: i64[>..] = [];    // 0 or 1

// Per element: two corners in 0..16 model space.
var mse_from: f32[>..] = [];
var mse_to: f32[>..] = [];

var ms_error: u8[>..] = [];

fn ms_reset() {
    mts_pool = []; mts_off = []; mts_len = [];
    mts_models = []; mts_names = [];
    msf_side = []; msf_elem = []; msf_face = []; msf_uv = []; msf_tex = [];
    msf_cull = []; msf_tint = []; msf_rot = []; msf_shade = [];
    mse_from = []; mse_to = [];
    ms_error = [];
}

fn ms_model_count() -> i64 { return mts_models.len; }

fn ms_model_name(i: i64) -> const u8[:] {
    if i < 0 || i >= mts_models.len { return ""; }
    let m = mts_models[i];
    return mts_names[m.name_off .. m.name_off + m.name_len]
}

fn ms_model_find(name: const u8[:]) -> i64 {
    for i in mts_models.len {
        if eq_bytes(ms_model_name(i), name) { return i; }
    }
    return -1;
}

fn ms_face_start(m: i64) -> i64 { return mts_models[m].face_start; }
fn ms_face_count(m: i64) -> i64 { return mts_models[m].face_count; }
fn ms_elem_start(m: i64) -> i64 { return mts_models[m].elem_start; }
fn ms_elem_count(m: i64) -> i64 { return mts_models[m].elem_count; }
fn ms_model_full(m: i64) -> bool { return mts_models[m].full; }
fn ms_model_has_any(m: i64) -> bool { return mts_models[m].has_any; }

fn ms_elem_lo(e: i64, axis: i64) -> f32 { return mse_from[e * 3 + axis]; }
fn ms_elem_hi(e: i64, axis: i64) -> f32 { return mse_to[e * 3 + axis]; }

// --- the model being built ----------------------------------------------
//
// Textures arrive as a map the caller fills before each build (the jar's model
// chains are walked by the caller, which is the only part that needs the zip).

var msb_key_off: i64[>..] = [];
var msb_key_len: i64[>..] = [];
var msb_val_off: i64[>..] = [];
var msb_val_len: i64[>..] = [];
var msb_pool: u8[>..] = [];

fn ms_tex_reset() {
    msb_key_off = []; msb_key_len = []; msb_val_off = []; msb_val_len = []; msb_pool = [];
}

fn ms_tex_put(key: const u8[:], val: const u8[:]) {
    for i in msb_key_off.len {
        if eq_bytes(msb_pool[msb_key_off[i] .. msb_key_off[i] + msb_key_len[i]], key) {
            // A child's definition wins; the caller merges parents first, so a later
            // put is a child overriding a parent.
            msb_val_off[i] = msb_pool.len;
            for b in val { msb_pool.push(b); }
            msb_val_len[i] = val.len as i64;
            return;
        }
    }
    msb_key_off.push(msb_pool.len);
    for b in key { msb_pool.push(b); }
    msb_key_len.push(key.len as i64);
    msb_val_off.push(msb_pool.len);
    for b in val { msb_pool.push(b); }
    msb_val_len.push(val.len as i64);
}

fn ms_tex_get(key: const u8[:]) -> i64 {
    for i in msb_key_off.len {
        if eq_bytes(msb_pool[msb_key_off[i] .. msb_key_off[i] + msb_key_len[i]], key) {
            return i;
        }
    }
    return -1;
}

fn ms_tex_count() -> i64 { return msb_key_off.len; }

// Resolve a face's texture variable. `#name` may point at another entry; a path
// that is already a path is returned as it stands. Missing is -1, which the mesher
// draws as the missing tile and counts.
fn ms_tex_resolve(var_name: const u8[:]) -> i64 {
    var cur: u8[>..] = [];
    for b in var_name { cur.push(b); }
    var hops = 0;
    while hops < 8 && cur.len > 1 && cur[0] == '#' {
        let key = cur[1..];
        let i = ms_tex_get(key);
        if i < 0 { return -1; }
        cur = [];
        for b in msb_pool[msb_val_off[i] .. msb_val_off[i] + msb_val_len[i]] { cur.push(b); }
        hops += 1;
    }
    if cur.len == 0 || cur[0] == '#' { return -1; }
    var full: u8[>..] = [];
    if !starts_with(cur, "minecraft:") {
        for b in "minecraft:" { full.push(b); }
    }
    for b in cur { full.push(b); }
    return ms_path_intern(full);
}

// --- building one model --------------------------------------------------

// The mesher's face order (0 -Y, 1 +Y, 2 -Z, 3 +Z, 4 -X, 5 +X) mapped to the jar's
// names. Kept as a function because Goose cannot index an array of fixed arrays.
fn ms_face_index_by_name(name: const u8[:]) -> i64 {
    if eq_bytes(name, "down") { return 0; }
    if eq_bytes(name, "up") { return 1; }
    if eq_bytes(name, "north") { return 2; }
    if eq_bytes(name, "south") { return 3; }
    if eq_bytes(name, "west") { return 4; }
    if eq_bytes(name, "east") { return 5; }
    return -1;
}

// Deep-copies a JSON number, tolerating both integer and decimal forms.
fn ms_num(node: i64, axis: i64) -> f32 {
    if !json_valid(node) { return 0.0; }
    if json_is(node, J_ARR) {
        let v = json_at(node, axis);
        if json_valid(v) { return json_num(v) as f32; }
        return 0.0;
    }
    return 0.0;
}

fn ms_set_error(msg: const u8[:]) {
    ms_error = [];
    format(ms_error, msg);
}

fn ms_error_text() -> const u8[:] { return ms_error }

// Builds one model from a resolved JSON node whose `textures` are already in the
// map above, and whose parent chain (if any) the caller has already merged into it.
// Returns the model index, or -1 with `ms_error_text` set.
fn ms_build(name: const u8[:], root: i64) -> i64 {
    var rec = ModelRec {
        name_off: mts_names.len,
        name_len: name.len as i64,
        face_start: msf_side.len,
        face_count: 0,
        elem_start: mse_from.len / 3,
        elem_count: 0,
        full: false,
        has_any: false,
    };
    for b in name { mts_names.push(b); }

    let elements = json_get(root, "elements");
    if json_is(elements, J_ARR) {
        var e = json_first(elements);
        var elem_i = rec.elem_start;
        while e >= 0 {
            let from = json_get(e, "from");
            let to = json_get(e, "to");
            if !json_is(from, J_ARR) || !json_is(to, J_ARR) {
                ms_set_error("an element without from/to");
                return -1;
            }
            for axis in 3 { mse_from.push(ms_num(from, axis)); }
            for axis in 3 { mse_to.push(ms_num(to, axis)); }
            rec.elem_count += 1;
            let faces = json_get(e, "faces");
            if json_is(faces, J_OBJ) {
                var f = json_first(faces);
                while f >= 0 {
                    let side = ms_face_index_by_name(json_key(f));
                    if side >= 0 {
                        let tex_node = json_get(f, "texture");
                        var tex: i64 = -1;
                        if json_is(tex_node, J_STR) {
                            tex = ms_tex_resolve(json_str(tex_node));
                        }
                        // uv: four numbers in model space; default is the face's own
                        // extent, which is what the jar omits.
                        var uv: f32[4] = [0.0, 0.0, 16.0, 16.0];
                        let uv_node = json_get(f, "uv");
                        if json_is(uv_node, J_ARR) {
                            for k in 4 {
                                let v = json_at(uv_node, k);
                                if json_valid(v) { uv[k] = json_num(v) as f32; }
                            }
                        } else {
                            ms_default_uv(side, elem_i, uv);
                        }
                        let cull_node = json_get(f, "cullface");
                        var cull: i64 = -1;
                        if json_is(cull_node, J_STR) {
                            cull = ms_face_index_by_name(json_str(cull_node));
                        }
                        var tint: i64 = -1;
                        let tint_node = json_get(f, "tintindex");
                        if json_valid(tint_node) { tint = json_int(tint_node); }
                        var rot: i64 = 0;
                        let rot_node = json_get(f, "rotation");
                        if json_valid(rot_node) { rot = (json_int(rot_node) / 90) % 4; }
                        if rot < 0 { rot += 4; }
                        var shade: i64 = 1;
                        if json_valid(json_get(f, "shade")) {
                            if !json_get_bool(f, "shade") { shade = 0; }
                        }
                        msf_side.push(side as i64);
                        msf_elem.push(elem_i);
                        msf_face.push(side as i64);
                        for k in 4 { msf_uv.push(uv[k]); }
                        msf_tex.push(tex);
                        msf_cull.push(cull);
                        msf_tint.push(tint);
                        msf_rot.push(rot);
                        msf_shade.push(shade);
                        rec.face_count += 1;
                        rec.has_any = true;
                    }
                    f = json_next(f);
                }
            }
            elem_i += 1;
            e = json_next(e);
        }
    }
    // A "full cube" is one element filling the block with all six faces: the only
    // model that lets a neighbour cull a face.
    if rec.elem_count == 1 && rec.face_count == 6 {
        var fills = true;
        for axis in 3 {
            if mse_from[rec.elem_start * 3 + axis] > 0.001 { fills = false; }
            if mse_to[rec.elem_start * 3 + axis] < 15.999 { fills = false; }
        }
        rec.full = fills;
    }
    mts_models.push(rec);
    return mts_models.len - 1;
}

// The uv a face gets when the model does not name one: the face's own rectangle in
// model space, with the orientation the jar uses (north/south mirror u, up/down use
// x/z, and so on).
fn ms_default_uv(side: i64, e: i64, uv: f32[4]&) {
    let x0 = mse_from[e * 3 + 0]; let y0 = mse_from[e * 3 + 1]; let z0 = mse_from[e * 3 + 2];
    let x1 = mse_to[e * 3 + 0]; let y1 = mse_to[e * 3 + 1]; let z1 = mse_to[e * 3 + 2];
    if side == 0 || side == 1 {       // down, up: u = x, v = z
        uv[0] = x0; uv[1] = z0; uv[2] = x1; uv[3] = z1;
    } else if side == 2 {             // north (-Z): u = 16-x, v = 16-y
        uv[0] = 16.0 - x1; uv[1] = 16.0 - y1; uv[2] = 16.0 - x0; uv[3] = 16.0 - y0;
    } else if side == 3 {             // south (+Z): u = x, v = 16-y
        uv[0] = x0; uv[1] = 16.0 - y1; uv[2] = x1; uv[3] = 16.0 - y0;
    } else if side == 4 {             // west (-X): u = z, v = 16-y
        uv[0] = z0; uv[1] = 16.0 - y1; uv[2] = z1; uv[3] = 16.0 - y0;
    } else {                          // east (+X): u = 16-z, v = 16-y
        uv[0] = 16.0 - z1; uv[1] = 16.0 - y1; uv[2] = 16.0 - z0; uv[3] = 16.0 - y0;
    }
}

// --- blockstates ---------------------------------------------------------

struct BsRule {
    model: i64,        // model index, -1 if the model was missing
    model_path_off: i64,
    model_path_len: i64,
    xrot: i64,         // 0, 90, 180, 270
    yrot: i64,
    uvlock: bool,
    weight: i64,
    cond_start: i64,   // conditions, empty for a `variants` rule
    cond_count: i64,
    variant_key_off: i64,
    variant_key_len: i64,
    is_variant: bool,
}

struct BsRec {
    name_off: i64,
    name_len: i64,
    rule_start: i64,
    rule_count: i64,
    multipart: bool,
    ok: bool,
}

var mts_bs: BsRec[>..] = [];
var mts_bs_names: u8[>..] = [];
var mts_rules: BsRule[>..] = [];
var mts_rule_pool: u8[>..] = [];
// Conditions: property name, then the values it may take, as "a|b".
var mts_cond_key_off: i64[>..] = [];
var mts_cond_key_len: i64[>..] = [];
var mts_cond_val_off: i64[>..] = [];
var mts_cond_val_len: i64[>..] = [];
var mts_cond_pool: u8[>..] = [];
var mts_cond_any: bool[>..] = [];   // true when the clause is an OR group

fn ms_bs_count() -> i64 { return mts_bs.len; }

fn ms_bs_name(i: i64) -> const u8[:] {
    if i < 0 || i >= mts_bs.len { return ""; }
    let b = mts_bs[i];
    return mts_bs_names[b.name_off .. b.name_off + b.name_len]
}

fn ms_bs_find(name: const u8[:]) -> i64 {
    for i in mts_bs.len {
        if eq_bytes(ms_bs_name(i), name) { return i; }
    }
    return -1;
}

fn ms_rule_model_path(r: i64) -> const u8[:] {
    let x = mts_rules[r];
    return mts_rule_pool[x.model_path_off .. x.model_path_off + x.model_path_len]
}

fn ms_rule_count() -> i64 { return mts_rules.len; }

// Rules still without a model after `ms_link_models`: a blockstate that names a model
// the jar does not have. Reported rather than hidden, because a rule that resolves
// nowhere is a block that draws nothing.
fn ms_rules_unlinked() -> i64 {
    var n: i64 = 0;
    for r in mts_rules.len {
        if mts_rules[r].model < 0 { n += 1; }
    }
    return n;
}
fn ms_rule_model(r: i64) -> i64 { return mts_rules[r].model; }
fn ms_rule_xrot(r: i64) -> i64 { return mts_rules[r].xrot; }
fn ms_rule_yrot(r: i64) -> i64 { return mts_rules[r].yrot; }
fn ms_rule_uvlock(r: i64) -> bool { return mts_rules[r].uvlock; }
fn ms_rule_weight(r: i64) -> i64 { return mts_rules[r].weight; }
fn ms_rule_is_variant(r: i64) -> bool { return mts_rules[r].is_variant; }

fn ms_rule_key(r: i64) -> const u8[:] {
    let x = mts_rules[r];
    if x.variant_key_len == 0 { return ""; }
    return mts_rule_pool[x.variant_key_off .. x.variant_key_off + x.variant_key_len]
}

fn ms_rule_cond_count(r: i64) -> i64 { return mts_rules[r].cond_count; }
fn ms_cond_key(c: i64) -> const u8[:] {
    return mts_cond_pool[mts_cond_key_off[c] .. mts_cond_key_off[c] + mts_cond_key_len[c]]
}
fn ms_cond_values(c: i64) -> const u8[:] {
    return mts_cond_pool[mts_cond_val_off[c] .. mts_cond_val_off[c] + mts_cond_val_len[c]]
}

fn ms_pool_str(s: const u8[:]) -> i64 {
    let off = mts_rule_pool.len;
    for b in s { mts_rule_pool.push(b); }
    return off
}

fn ms_cond_new(key: const u8[:], values: const u8[:]) -> i64 {
    mts_cond_key_off.push(mts_cond_pool.len);
    for b in key { mts_cond_pool.push(b); }
    mts_cond_key_len.push(key.len as i64);
    mts_cond_val_off.push(mts_cond_pool.len);
    for b in values { mts_cond_pool.push(b); }
    mts_cond_val_len.push(values.len as i64);
    mts_cond_any.push(false);
    return mts_cond_key_off.len - 1;
}

// A `when` object: every property in it must be one of the listed values. The values
// are a `|` separated list, which is how vanilla writes alternatives. The conditions
// are appended to the global table and the count is returned, because there is no
// closure to hand out and an array parameter that is grown inside a callee is a trap
// worth not setting.
var mts_when_start: i64 = 0;

fn ms_parse_when(node: i64) -> i64 {
    mts_when_start = mts_cond_key_off.len;
    if !json_is(node, J_OBJ) { return 0; }
    var p = json_first(node);
    var any: i64 = 0;
    while p >= 0 {
        // In this JSON tree a member is the value node itself, carrying its key, so
        // `p` is the value and `json_key(p)` is the property name.
        if json_is(p, J_STR) {
            ms_cond_new(json_key(p), json_str(p));
            any += 1;
        }
        p = json_next(p);
    }
    return any;
}

fn ms_add_rule(model_path: const u8[:], apply: i64, key: const u8[:], cond_start: i64,
               cond_count: i64, is_variant: bool) {
    var xrot: i64 = 0;
    var yrot: i64 = 0;
    var uvlock = false;
    var weight: i64 = 1;
    var want = model_path;
    if json_is(apply, J_OBJ) {
        let n = json_get_str(apply, "model");
        if n.len > 0 { want = n; }
        xrot = json_get_int(apply, "x");
        yrot = json_get_int(apply, "y");
        uvlock = json_get_bool(apply, "uvlock");
        let w = json_get_int(apply, "weight");
        if w > 0 { weight = w; }
    }
    mts_rules.push(BsRule {
        model: ms_model_find(want),
        model_path_off: ms_pool_str(want),
        model_path_len: want.len as i64,
        xrot: ((xrot / 90) % 4 + 4) % 4 * 90,
        yrot: ((yrot / 90) % 4 + 4) % 4 * 90,
        uvlock: uvlock,
        weight: weight,
        cond_start: cond_start,
        cond_count: cond_count,
        variant_key_off: ms_pool_str(key),
        variant_key_len: key.len as i64,
        is_variant: is_variant,
    });
}

// Parses one blockstate file. Models named here that the store has not seen yet are
// left as -1; the caller builds models before blockstates, and a later
// `ms_link_models()` fills them in once every model exists.
fn ms_bs_build(name: const u8[:], root: i64) -> i64 {
    var rec = BsRec {
        name_off: mts_bs_names.len,
        name_len: name.len as i64,
        rule_start: mts_rules.len,
        rule_count: 0,
        multipart: false,
        ok: true,
    };
    for b in name { mts_bs_names.push(b); }

    let variants = json_get(root, "variants");
    if json_is(variants, J_OBJ) {
        var v = json_first(variants);
        while v >= 0 {
            let key = json_key(v);
            let body = v;
            // The value is either one apply object or an array of weighted ones.
            if json_is(body, J_ARR) {
                var a = json_first(body);
                while a >= 0 {
                    ms_add_rule("", a, key, 0, 0, true);
                    rec.rule_count += 1;
                    a = json_next(a);
                }
            } else if json_is(body, J_OBJ) {
                ms_add_rule("", body, key, 0, 0, true);
                rec.rule_count += 1;
            }
            v = json_next(v);
        }
    } else {
        let parts = json_get(root, "multipart");
        if json_is(parts, J_ARR) {
            rec.multipart = true;
            var p = json_first(parts);
            while p >= 0 {
                let when = json_get(p, "when");
                let apply = json_get(p, "apply");
                if json_is(when, J_ARR) {
                    // An array of `when` objects is an OR: each branch becomes its own
                    // rule with the same apply, which is equivalent and keeps the
                    // matcher one flat loop.
                    var w = json_first(when);
                    while w >= 0 {
                        let n = ms_parse_when(w);
                        if n > 0 {
                            ms_add_rule("", apply, "", mts_when_start, n, false);
                            rec.rule_count += 1;
                        }
                        w = json_next(w);
                    }
                    p = json_next(p);
                    continue;
                }
                var cond_start = mts_cond_key_off.len;
                var cond_count: i64 = 0;
                if json_is(when, J_OBJ) {
                    cond_count = ms_parse_when(when);
                    cond_start = mts_when_start;
                }
                if json_is(apply, J_ARR) {
                    var a = json_first(apply);
                    while a >= 0 {
                        ms_add_rule("", a, "", cond_start, cond_count, false);
                        rec.rule_count += 1;
                        a = json_next(a);
                    }
                } else {
                    ms_add_rule("", apply, "", cond_start, cond_count, false);
                    rec.rule_count += 1;
                }
                p = json_next(p);
            }
        } else {
            rec.ok = false;
        }
    }
    if rec.rule_count == 0 { rec.ok = false; }
    mts_bs.push(rec);
    return mts_bs.len - 1;
}

// Fills in every rule whose model was built after its blockstate was parsed.
fn ms_link_models() -> i64 {
    var linked = 0;
    var qualified: u8[>..] = [];
    for r in mts_rules.len {
        if mts_rules[r].model >= 0 { continue; }
        // A blockstate may name a model without a namespace - the client reads
        // "block/oak_planks" as "minecraft:block/oak_planks" - so qualify it before
        // looking it up, or every vanilla blockstate misses its model.
        let raw = ms_rule_model_path(r);
        var m: i64 = -1;
        if starts_with(raw, "minecraft:") {
            m = ms_model_find(raw);
        } else {
            qualified = [];
            qualified.append("minecraft:");
            for b in raw { qualified.push(b); }
            m = ms_model_find(qualified[..]);
        }
        if m >= 0 {
            mts_rules[r].model = m;
            linked += 1;
        }
    }
    return linked;
}

fn ms_rule_missing_model(r: i64) -> bool { return mts_rules[r].model < 0; }

// --- matching a block state against a blockstate file --------------------

// Is `props` ("facing=north,half=bottom") giving `key` one of `values` ("a|b")?
fn ms_prop_is(props: const u8[:], key: const u8[:], values: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < props.len {
        var j = i;
        while j < props.len && props[j] != ',' { j += 1; }
        let part = props[i..j];
        // part is "k=v"
        var eq: i64 = -1;
        for k in part.len {
            if part[k] == '=' { eq = k; }
        }
        if eq > 0 && eq_bytes(part[..eq], key) {
            let v = part[eq + 1 ..];
            // v must be one of the alternatives
            var a: i64 = 0;
            while a < values.len {
                var b = a;
                while b < values.len && values[b] != '|' { b += 1; }
                if eq_bytes(values[a..b], v) { return true; }
                a = b + 1;
            }
            return false;
        }
        i = j + 1;
    }
    return false;
}

fn ms_variant_matches(key: const u8[:], props: const u8[:]) -> bool {
    // Every `k=v` in the key must be true of the block. An empty key is the client's
    // "this block has one state" spelling and matches any state, properties or not:
    // `{"variants": {"": {...}}}` is how the jar writes the blocks that do not vary.
    if key.len == 0 { return true; }
    var i: i64 = 0;
    while i < key.len {
        var j = i;
        while j < key.len && key[j] != ',' { j += 1; }
        let part = key[i..j];
        var eq: i64 = -1;
        for k in part.len {
            if part[k] == '=' { eq = k; }
        }
        if eq <= 0 { return false; }
        if !ms_prop_is(props, part[..eq], part[eq + 1 ..]) { return false; }
        i = j + 1;
    }
    return true;
}

fn ms_rule_matches(r: i64, props: const u8[:]) -> bool {
    let x = mts_rules[r];
    if x.model < 0 { return false; }
    if x.is_variant {
        return ms_variant_matches(ms_rule_key(r), props);
    }
    var c = x.cond_start;
    let end = x.cond_start + x.cond_count;
    while c < end {
        if !ms_prop_is(props, ms_cond_key(c), ms_cond_values(c)) { return false; }
        c += 1;
    }
    return true;
}

// The rules that draw a block: the matches, with weighted variants reduced to one by
// `hash` (the block's own position, so the choice is stable across remeshes).
var ms_sel_rule: i64[>..] = [];
var ms_sel_pool: i64[>..] = [];

fn ms_select(bs: i64, props: const u8[:], hash: i64) -> i64 {
    ms_sel_rule = [];
    if bs < 0 || bs >= mts_bs.len { return 0; }
    let rec = mts_bs[bs];
    // Collect matches.
    ms_sel_pool = [];
    var want: i64 = 0;
    for k in rec.rule_count {
        let r = rec.rule_start + k;
        if !ms_rule_matches(r, props) { continue; }
        ms_sel_pool.push(r);
        want += mts_rules[r].weight;
    }
    if ms_sel_pool.len == 0 { return 0; }
    if !rec.multipart && want > 1 {
        // Weighted choice: one variant only, picked by the block's position.
        var pick = hash % want;
        if pick < 0 { pick += want; }
        for i in ms_sel_pool.len {
            let w = mts_rules[ms_sel_pool[i]].weight;
            if pick < w {
                ms_sel_rule.push(ms_sel_pool[i]);
                return 1;
            }
            pick -= w;
        }
    }
    for i in ms_sel_pool.len {
        ms_sel_rule.push(ms_sel_pool[i]);
    }
    return ms_sel_rule.len;
}

fn ms_sel_count() -> i64 { return ms_sel_rule.len; }
fn ms_sel_at(i: i64) -> i64 { return ms_sel_rule[i]; }
