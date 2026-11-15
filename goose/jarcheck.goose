// Umbra jar check: reads the official client jar and checks what the client
// would need from it.
//
// Version 2. The first version checked every model in the jar on its own, and
// the real jar (26.3) showed why that is wrong: `block/cube_all.json` is a
// *template* whose `textures` say `"all": "#all"` — a slot a child fills in —
// and `block/air.json` names a texture (`block/air`) that does not exist because
// air is never drawn. Neither is a fault. What matters is the models a
// blockstate can actually put on screen.
//
// So this version walks the model chain the way the client does: for each model
// a blockstate references, merge the textures of the model and its parents
// (the child's definition wins), take the elements of the first model in the
// chain that has any, and resolve every face's `#key` through the merged map to a
// PNG that exists. Inverted boxes are allowed: `cube_all_inner_faces` has them on
// purpose. Animated textures are strips (16x512), not squares, so a texture only
// has to be a whole number of square frames.
//
// The jar is downloaded by tools/fetch_jar.sh at test time and is never
// committed.
//
//   umbra_jarcheck <client.jar>

import std;
import os;
import core.mem;
import core.zip;
import core.json;
import core.png;

const JC_TABLE_BITS: i64 = 16;
const JC_TABLE_SIZE: i64 = 1 << JC_TABLE_BITS;
const JC_MAX_CHAIN: i64 = 16;

var jc_jar: u8[>..] = [];         // the whole jar
var jc_tmp: u8[>..] = [];         // one extracted entry, reused
var jc_path: u8[>..] = [];        // scratch for building paths
var jc_pool: u8[>..] = [];        // names, appended and never removed
var jc_table: i64[>..] = [];      // open-addressed entry-name table
var jc_archive: i64 = -1;
var jc_cur: u8[>..] = [];         // the entry being checked, for messages

var jc_blocks: i64 = 0;
var jc_models: i64 = 0;
var jc_textures: i64 = 0;
var jc_model_refs: i64 = 0;
var jc_used_models: i64 = 0;      // distinct models a blockstate names
var jc_used_with_elements: i64 = 0;
var jc_parent_hops: i64 = 0;
var jc_parents: i64 = 0;
var jc_builtin_parents: i64 = 0;
var jc_elements: i64 = 0;
var jc_faces: i64 = 0;
var jc_faces_resolved: i64 = 0;
var jc_var_hops: i64 = 0;
var jc_inverted_boxes: i64 = 0;
var jc_multipart: i64 = 0;
var jc_weighted: i64 = 0;
var jc_uv_present: i64 = 0;
var jc_unused_models: i64 = 0;

var jc_problems: u8[>..] = [];
var jc_problem_count: i64 = 0;
var jc_reported: i64 = 0;
const JC_MAX_REPORTED: i64 = 30;

fn jc_fail(msg: const u8[:]) -> i64 {
    print("FAIL: ", msg);
    exit(1);
    return 0;
}

fn jc_set_file(name: u8[:]) {
    jc_cur = [];
    for i in name.len { jc_cur.push(name[i]); }
}

fn jc_problem(msg: const u8[:]) {
    jc_problem_count += 1;
    if jc_reported < JC_MAX_REPORTED {
        jc_reported += 1;
        jc_problems.push(10);
        for i in jc_cur.len { jc_problems.push(jc_cur[i]); }
        let sep = ": ";
        for i in sep.len { jc_problems.push(sep[i]); }
        for i in msg.len { jc_problems.push(msg[i]); }
    }
}

fn jc_starts_with(s: const u8[:], head: const u8[:]) -> bool {
    if s.len < head.len { return false; }
    for i in head.len {
        if s[i] != head[i] { return false; }
    }
    return true;
}

fn jc_ends_with(s: const u8[:], tail: const u8[:]) -> bool {
    if s.len < tail.len { return false; }
    let off = s.len - tail.len;
    for i in tail.len {
        if s[off + i] != tail[i] { return false; }
    }
    return true;
}

fn jc_fnv1a(s: const u8[:]) -> i64 {
    var h: u32 = 2166136261;
    for i in s.len {
        h = (h ^ (s[i] as u32)) * 16777619;
    }
    return (h & (JC_TABLE_SIZE - 1)) as i64;
}

fn jc_table_build() {
    jc_table = [];
    for i in JC_TABLE_SIZE { jc_table.push(-1); }
    let a = zip_archives[jc_archive];
    for k in a.count {
        let e = a.first + k;
        var h = jc_fnv1a(zip_name_of(zip_entries[e]));
        while jc_table[h] >= 0 {
            h = (h + 1) & (JC_TABLE_SIZE - 1);
        }
        jc_table[h] = e;
    }
}

fn jc_find(name: const u8[:]) -> i64 {
    var h = jc_fnv1a(name);
    while true {
        let e = jc_table[h];
        if e < 0 { return -1; }
        let en = zip_name_of(zip_entries[e]);
        if en.len == name.len && eq_bytes(en, name) { return e; }
        h = (h + 1) & (JC_TABLE_SIZE - 1);
    }
    return -1;
}

// Pins a name in jc_pool and returns where it sits.
fn jc_pin(name: const u8[:]) -> Sref {
    let off = jc_pool.len;
    for i in name.len { jc_pool.push(name[i]); }
    return Sref { off: off, len: name.len };
}

fn jc_pinned(s: Sref) -> u8[:] { return jc_pool[s.off .. s.off + s.len] }

fn jc_pin_str(s: Sref) -> const u8[:] { return jc_pool[s.off .. s.off + s.len]; }

// "minecraft:block/stone" -> "block/stone".
fn jc_no_ns(s: const u8[:]) -> const u8[:] {
    let ns = "minecraft:";
    if s.len > ns.len && jc_starts_with(s, ns) { return s[ns.len ..]; }
    return s;
}

fn jc_models_path(name: const u8[:], out: u8[>..]&) {
    out = [];
    for i in "assets/minecraft/models/".len { out.push("assets/minecraft/models/"[i]); }
    for i in name.len { out.push(name[i]); }
    for i in 5 { out.push(".json"[i]); }
}

fn jc_textures_path(name: const u8[:], out: u8[>..]&) {
    out = [];
    for i in "assets/minecraft/textures/".len { out.push("assets/minecraft/textures/"[i]); }
    for i in name.len { out.push(name[i]); }
    for i in 4 { out.push(".png"[i]); }
}

// An extracted entry's bytes, or an empty slice (with a problem) on error.
fn jc_extract(entry: i64) -> const u8[:] {
    jc_tmp = [];
    let ok, err = zip_extract(jc_jar[..], entry, jc_tmp);
    if !ok {
        jc_problem(err);
        return jc_tmp[0..0];
    }
    return jc_tmp[..];
}

fn jc_entry_for_model(name: const u8[:]) -> i64 {
    jc_models_path(jc_no_ns(name), jc_path);
    return jc_find(jc_path[..]);
}

fn jc_known_builtin(name: const u8[:]) -> bool {
    if eq_bytes(name, "builtin/entity") { return true; }
    if eq_bytes(name, "builtin/generated") { return true; }
    if eq_bytes(name, "builtin/missing") { return true; }
    return false;
}

// The parent entry of a parsed model, or -1 (and a problem if it is named but
// missing).
fn jc_parent_entry(root: i64) -> i64 {
    let parent = json_get(root, "parent");
    if parent < 0 { return -1; }
    if json_kind(parent) != J_STR {
        jc_problem("a parent that is not a string");
        return -1;
    }
    let name = jc_no_ns(json_str(parent));
    if jc_known_builtin(name) {
        jc_builtin_parents += 1;
        return -1;
    }
    let e = jc_entry_for_model(name);
    if e < 0 { jc_problem("a parent model that does not exist"); }
    return e;
}

// --- the merged texture map of one model chain --------------------------
//
// Parallel arrays of pinned names: the key a face says (`#all`) and what it
// stands for (`block/oak_planks` or `#other`). The first chain entry to define a
// key wins, which is the child, because the walk starts at the child.
var jc_keys: Sref[>..] = [];
var jc_vals: Sref[>..] = [];

fn jc_tex_has(key: const u8[:]) -> bool {
    for i in jc_keys.len {
        let k = jc_pin_str(jc_keys[i]);
        if k.len == key.len && eq_bytes(k, key) { return true; }
    }
    return false;
}

fn jc_tex_add(key: const u8[:], val: const u8[:]) {
    if jc_tex_has(key) { return; }
    jc_keys.push(jc_pin(key));
    jc_vals.push(jc_pin(val));
}

fn jc_tex_get(key: const u8[:]) -> Sref {
    for i in jc_keys.len {
        let k = jc_pin_str(jc_keys[i]);
        if k.len == key.len && eq_bytes(k, key) { return jc_vals[i]; }
    }
    return Sref { off: -1, len: 0 };
}

// Merges the chain's textures (child first) and returns the entry whose elements
// are the model's, or -1 when no model in the chain has any.
fn jc_merge_chain(entry: i64) -> i64 {
    jc_keys = [];
    jc_vals = [];
    var elements_owner: i64 = -1;
    var cur = entry;
    var hops: i64 = 0;
    while cur >= 0 && hops < JC_MAX_CHAIN {
        let text = jc_extract(cur);
        if text.len == 0 { break; }
        let root = json_parse(text);
        if root < 0 || json_kind(root) != J_OBJ {
            jc_problem("a model that does not parse as an object");
            break;
        }
        let textures = json_get(root, "textures");
        if textures >= 0 && json_kind(textures) == J_OBJ {
            var c = json_first(textures);
            while c >= 0 {
                if json_kind(c) == J_STR {
                    jc_tex_add(json_key(c), json_str(c));
                }
                c = json_next(c);
            }
        }
        if elements_owner < 0 {
            let el = json_get(root, "elements");
            if el >= 0 && json_kind(el) == J_ARR { elements_owner = cur; }
        }
        let next = jc_parent_entry(root);
        if next >= 0 {
            jc_parents += 1;
            jc_parent_hops += 1;
        }
        cur = next;
        hops += 1;
    }
    return elements_owner;
}

// Resolves a face's texture key through the merged map. Returns the PNG entry
// index, or -1 with a problem.
fn jc_resolve_face_tex(key: const u8[:]) -> i64 {
    var name = key;
    var hops: i64 = 0;
    while hops < JC_MAX_CHAIN {
        let v = jc_tex_get(name);
        if v.off < 0 {
            jc_problem("a face texture key that no model in the chain defines");
            return -1;
        }
        let val = jc_pin_str(v);
        if val.len == 0 {
            jc_problem("a texture defined as an empty name");
            return -1;
        }
        if val[0] != 35 {
            jc_textures_path(jc_no_ns(val), jc_path);
            let e = jc_find(jc_path[..]);
            if e < 0 { jc_problem("a face whose texture has no PNG in the jar"); }
            return e;
        }
        jc_var_hops += 1;
        // Copy the next key before anything can grow the pool under us.
        let next = jc_pin(val[1 ..]);
        name = jc_pinned(next);
        hops += 1;
    }
    jc_problem("a texture variable chain longer than 16");
    return -1;
}

fn jc_check_box(el: i64) {
    let from = json_get(el, "from");
    let to = json_get(el, "to");
    if from < 0 || to < 0 {
        jc_problem("a box without from/to");
        return;
    }
    if json_kind(from) != J_ARR || json_kind(to) != J_ARR {
        jc_problem("a box whose from/to is not an array");
        return;
    }
    if json_child_count(from) != 3 || json_child_count(to) != 3 {
        jc_problem("a box whose from/to does not have three numbers");
        return;
    }
    var inverted = false;
    for axis in 3 {
        let f = json_at(from, axis);
        let t = json_at(to, axis);
        if json_kind(f) != J_NUM || json_kind(t) != J_NUM {
            jc_problem("a box coordinate that is not a number");
            return;
        }
        if json_num(f) > json_num(t) { inverted = true; }
    }
    // Inverted boxes are legal: the client uses them for inner faces.
    if inverted { jc_inverted_boxes += 1; }

    let rotation = json_get(el, "rotation");
    if rotation >= 0 {
        if json_kind(rotation) != J_OBJ {
            jc_problem("a rotation that is not an object");
        } else {
            let angle = json_get(rotation, "angle");
            if angle < 0 || json_kind(angle) != J_NUM {
                jc_problem("a box rotation without a numeric angle");
            }
            let axis = json_get(rotation, "axis");
            if axis < 0 || json_kind(axis) != J_STR {
                jc_problem("a box rotation without an axis");
            }
        }
    }

    let faces = json_get(el, "faces");
    if faces < 0 { return; }
    if json_kind(faces) != J_OBJ {
        jc_problem("a faces field that is not an object");
        return;
    }
    var f = json_first(faces);
    while f >= 0 {
        jc_faces += 1;
        let tex = json_get(f, "texture");
        if tex < 0 || json_kind(tex) != J_STR {
            jc_problem("a face without a texture key");
        } else {
            let key = json_str(tex);
            if key.len < 2 || key[0] != 35 {
                jc_problem("a face texture key that is not #name");
            } else {
                let pinned = jc_pin(key[1 ..]);
                if jc_resolve_face_tex(jc_pinned(pinned)) >= 0 { jc_faces_resolved += 1; }
            }
        }
        let uv = json_get(f, "uv");
        if uv >= 0 {
            if json_kind(uv) != J_ARR || json_child_count(uv) != 4 {
                jc_problem("a face whose uv is not four numbers");
            } else {
                var ok = true;
                for k in 4 {
                    if json_kind(json_at(uv, k)) != J_NUM { ok = false; }
                }
                if ok { jc_uv_present += 1; } else { jc_problem("a uv entry that is not a number"); }
            }
        }
        let rotation2 = json_get(f, "rotation");
        if rotation2 >= 0 && json_kind(rotation2) != J_NUM {
            jc_problem("a face rotation that is not a number");
        }
        f = json_next(f);
    }
}

// A model a blockstate can render: merge its chain, then check the elements it
// inherits.
fn jc_check_used_model(entry: i64) {
    jc_set_file(zip_name_of(zip_entries[entry]));
    let owner = jc_merge_chain(entry);
    if owner < 0 { return; }
    jc_used_with_elements += 1;
    let text = jc_extract(owner);
    if text.len == 0 { return; }
    let root = json_parse(text);
    if root < 0 { return; }
    let elements = json_get(root, "elements");
    if elements < 0 { return; }
    if json_kind(elements) != J_ARR {
        jc_problem("an elements field that is not an array");
        return;
    }
    var el = json_first(elements);
    while el >= 0 {
        jc_elements += 1;
        jc_check_box(el);
        el = json_next(el);
    }
}

// --- blockstates ---------------------------------------------------------

var jc_used: u8[>..] = [];          // 1 for models a blockstate names, by entry
var jc_used_list: i64[>..] = [];    // and the same, in order, without repeats

fn jc_mark_used(entry: i64) {
    while jc_used.len <= entry { jc_used.push(0); }
    if jc_used[entry] == 0 {
        jc_used[entry] = 1;
        jc_used_list.push(entry);
    }
}

fn jc_ref_one(obj: i64) {
    let model = json_get(obj, "model");
    if model < 0 || json_kind(model) != J_STR {
        jc_problem("a variant without a model name");
        return;
    }
    jc_model_refs += 1;
    let e = jc_entry_for_model(json_str(model));
    if e < 0 {
        jc_problem("a blockstate referencing a model that does not exist");
        return;
    }
    jc_mark_used(e);
    let rx = json_get(obj, "x");
    if rx >= 0 && json_kind(rx) != J_NUM { jc_problem("a rotation that is not a number"); }
    let ry = json_get(obj, "y");
    if ry >= 0 && json_kind(ry) != J_NUM { jc_problem("a rotation that is not a number"); }
    let lock = json_get(obj, "uvlock");
    if lock >= 0 && json_kind(lock) != J_BOOL { jc_problem("a uvlock that is not a boolean"); }
}

fn jc_refs_in(node: i64) {
    let kind = json_kind(node);
    if kind == J_OBJ {
        jc_ref_one(node);
    } else if kind == J_ARR {
        jc_weighted += 1;
        var i = json_first(node);
        while i >= 0 {
            if json_kind(i) != J_OBJ {
                jc_problem("a weighted variant that is not an object");
            } else {
                jc_ref_one(i);
            }
            i = json_next(i);
        }
    } else {
        jc_problem("a variant that is neither an object nor an array");
    }
}

fn jc_check_blockstate(entry: i64) {
    jc_set_file(zip_name_of(zip_entries[entry]));
    let text = jc_extract(entry);
    if text.len == 0 { return; }
    let root = json_parse(text);
    if root < 0 {
        jc_problem(json_error());
        return;
    }
    if json_kind(root) != J_OBJ {
        jc_problem("a blockstate file whose root is not an object");
        return;
    }
    let variants = json_get(root, "variants");
    let multipart = json_get(root, "multipart");
    if variants >= 0 {
        if json_kind(variants) != J_OBJ {
            jc_problem("a variants field that is not an object");
        } else {
            var v = json_first(variants);
            while v >= 0 {
                jc_refs_in(v);
                v = json_next(v);
            }
        }
    }
    if multipart >= 0 {
        if json_kind(multipart) != J_ARR {
            jc_problem("a multipart field that is not an array");
        } else {
            jc_multipart += 1;
            var m = json_first(multipart);
            while m >= 0 {
                let apply = json_get(m, "apply");
                if apply < 0 {
                    jc_problem("a multipart case without apply");
                } else {
                    jc_refs_in(apply);
                }
                m = json_next(m);
            }
        }
    }
    if variants < 0 && multipart < 0 {
        jc_problem("a blockstate with neither variants nor multipart");
    }
}

fn main() {
    // The zip layer verifies CRCs, so its table must exist before the first
    // entry is pulled out.
    crc32_init();
    if arg_count() < 2 {
        jc_fail("usage: umbra_jarcheck <client.jar>");
        return;
    }
    var path: u8[>..] = [];
    arg(1, path);
    if !read_file(path[..], jc_jar) || jc_jar.len < 22 {
        jc_fail("the jar could not be read");
        return;
    }
    print("jar: read ", jc_jar.len, " bytes from ", path);

    let opened, err = zip_open("client.jar", jc_jar[..]);
    if !opened {
        jc_fail(err);
        return;
    }
    jc_archive = zip_archives.len - 1;
    let a = zip_archives[jc_archive];
    print("jar: ", a.count, " entries");
    jc_table_build();

    var block_entries: i64[>..] = [];
    var model_entries: i64[>..] = [];
    var texture_entries: i64[>..] = [];
    for k in a.count {
        let e = a.first + k;
        let name = zip_name_of(zip_entries[e]);
        if jc_ends_with(name, ".json") && jc_starts_with(name, "assets/minecraft/blockstates/") {
            block_entries.push(e);
        } else if jc_ends_with(name, ".json") && jc_starts_with(name, "assets/minecraft/models/") {
            model_entries.push(e);
        } else if jc_ends_with(name, ".png") && jc_starts_with(name, "assets/minecraft/textures/") {
            texture_entries.push(e);
        }
    }
    jc_blocks = block_entries.len;
    jc_models = model_entries.len;
    jc_textures = texture_entries.len;
    print("jar: blockstates ", jc_blocks, ", models ", jc_models, ", textures ", jc_textures);
    if jc_blocks < 500 { jc_problem("fewer than 500 blockstates"); }
    if jc_models < 1000 { jc_problem("fewer than 1000 models"); }
    if jc_textures < 500 { jc_problem("fewer than 500 textures"); }

    // Pass 1: every blockstate, and which models it puts on screen.
    for i in block_entries.len {
        jc_check_blockstate(block_entries[i]);
        if i % 500 == 0 { print("jar: blockstates ", i, "/", block_entries.len); }
    }
    jc_used_models = jc_used_list.len;

    // Pass 2: every model a blockstate can render, with its whole chain.
    for i in jc_used_list.len {
        jc_check_used_model(jc_used_list[i]);
        if i % 500 == 0 { print("jar: used models ", i, "/", jc_used_list.len); }
    }
    jc_unused_models = jc_models - jc_used_models;

    // Pass 3: a sample of textures, decoded. Animated textures are strips of
    // square frames, so the height must be a multiple of the width, not equal to
    // it.
    var decoded: i64 = 0;
    var sane: i64 = 0;
    var longest: i64 = 0;
    var animated: i64 = 0;
    var t: i64 = 0;
    // Every 25th texture, plus the last one, which is where a pack tends to put
    // something unusual.
    while t < texture_entries.len || t == texture_entries.len {
        if t == texture_entries.len {
            t = t - 25 + 1;
            if t < 0 || t >= texture_entries.len { break; }
        }
        jc_set_file(zip_name_of(zip_entries[texture_entries[t]]));
        let bytes = jc_extract(texture_entries[t]);
        if bytes.len > 0 {
            var palette: u8[>..] = [];
            var rgba: u8[>..] = [];
            let info, good, perr = png_decode(bytes, palette, rgba);
            if good {
                decoded += 1;
                if info.height > longest { longest = info.height; }
                let w = info.width;
                let h = info.height;
                if w >= 16 && w <= 1024 && h >= w && h <= 4096 && h % w == 0 {
                    sane += 1;
                    if h > w { animated += 1; }
                } else {
                    jc_problem("a texture that is not a whole number of square frames");
                }
            } else {
                jc_problem(perr);
            }
        }
        t += 25;
    }

    print("jar: blockstate model references ", jc_model_refs,
          ", distinct models used ", jc_used_models, " (", jc_unused_models, " unused)");
    print("jar: parent links followed ", jc_parent_hops,
          ", parents that exist ", jc_parents,
          ", builtin parents ", jc_builtin_parents);
    print("jar: used models with elements ", jc_used_with_elements,
          ", boxes ", jc_elements, ", faces ", jc_faces,
          ", faces whose texture resolved to a PNG ", jc_faces_resolved,
          ", uv sets ", jc_uv_present);
    print("jar: texture variable hops ", jc_var_hops,
          ", inverted boxes (legal) ", jc_inverted_boxes);
    print("jar: multipart blockstates ", jc_multipart, ", weighted variant lists ", jc_weighted);
    print("jar: textures decoded ", decoded, ", whole square frames ", sane,
          " (", animated, " animated strips), tallest ", longest, " px");
    print("jar: problems ", jc_problem_count);
    if jc_reported > 0 {
        print("jar: first problems", jc_problems[..]);
    }
    if jc_problem_count > 0 {
        print("FAILED: ", jc_problem_count, " problems in the jar's model data");
        exit(1);
    }
    // A pass with nothing measured is not a pass.
    if jc_faces == 0 || jc_faces_resolved != jc_faces {
        print("FAILED: faces checked ", jc_faces, " resolved ", jc_faces_resolved);
        exit(1);
    }
    print("PASS: every model a blockstate can render resolves through its chain (",
          jc_used_models, " models, ", jc_faces, " faces, ", jc_textures, " textures)");
}

// A C host needs at least one export; this names the tool.
export fn umbra_jarcheck_tool() -> const u8[:] { return "umbra-jarcheck" }
