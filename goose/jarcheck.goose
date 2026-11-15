// Umbra jar check: reads the official client jar and checks the model data
// against itself.
//
// This is the first half of gate 6. It does not trust the jar, it interrogates
// it: every blockstate must name a model that exists, every model's parent must
// exist (or be one of the built-in parents the client supplies itself), every
// texture a model names must exist as a PNG, every `#variable` must resolve to a
// texture, every box must have from <= to, and every face must carry four UV
// numbers. The numbers printed are measurements of the real data, which is what
// the parity table will be built on.
//
// The jar is downloaded by tools/fetch_jar.sh at test time and is never
// committed: the repository holds only the version pin and the checksum that
// download produced.
//
// Built and run by tools/build_jarcheck.sh:
//   umbra_jarcheck <client.jar>

import std;
import os;
import core.mem;
import core.zip;
import core.json;
import core.png;

const JC_TABLE_BITS: i64 = 16;
const JC_TABLE_SIZE: i64 = 1 << JC_TABLE_BITS;

var jc_jar: u8[>..] = [];        // the whole jar
var jc_tmp: u8[>..] = [];        // one extracted entry, reused
var jc_path: u8[>..] = [];       // scratch for building paths
var jc_table: i64[>..] = [];     // open-addressed entry-name table
var jc_archive: i64 = -1;

var jc_blocks: i64 = 0;          // blockstate files
var jc_models: i64 = 0;          // model files
var jc_textures: i64 = 0;        // png files
var jc_model_refs: i64 = 0;      // model references from blockstates
var jc_parents: i64 = 0;         // resolved model parents
var jc_builtin_parents: i64 = 0; // parents the client supplies itself
var jc_tex_refs: i64 = 0;        // resolved texture references
var jc_var_refs: i64 = 0;        // texture variables (#name)
var jc_elements: i64 = 0;        // boxes across all models
var jc_faces: i64 = 0;           // faces across all boxes
var jc_uv_ok: i64 = 0;           // faces with four UV numbers
var jc_multipart: i64 = 0;       // blockstates using multipart
var jc_weighted: i64 = 0;        // blockstates using weighted variants

var jc_problems: u8[>..] = [];   // one line per problem, capped
var jc_cur: u8[>..] = [];        // the entry being checked, for messages
var jc_vars: u8[>..] = [];       // names, appended and never removed
var jc_var_spans: Sref[>..] = []; // the ones the current model defers
var jc_problem_count: i64 = 0;
var jc_reported: i64 = 0;

const JC_MAX_REPORTED: i64 = 25;

fn jc_set_file(name: u8[:]) {
    jc_cur = [];
    for i in name.len { jc_cur.push(name[i]); }
}

// Every problem names the entry it was found in: a count with no locations is a
// number, not a bug report.
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

fn jc_fail(msg: const u8[:]) -> i64 {
    print("FAIL: ", msg);
    exit(1);
    return 0;
}

fn jc_ends_with(s: const u8[:], tail: const u8[:]) -> bool {
    if s.len < tail.len { return false; }
    let off = s.len - tail.len;
    for i in tail.len {
        if s[off + i] != tail[i] { return false; }
    }
    return true;
}

fn jc_starts_with(s: const u8[:], head: const u8[:]) -> bool {
    if s.len < head.len { return false; }
    for i in head.len {
        if s[i] != head[i] { return false; }
    }
    return true;
}

fn jc_fnv1a(s: const u8[:]) -> i64 {
    var h: u32 = 2166136261;
    for i in s.len {
        h = (h ^ (s[i] as u32)) * 16777619;
    }
    return (h & (JC_TABLE_SIZE - 1) as u32) as i64;
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

// The entry index for an exact entry name, or -1.
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

// "minecraft:block/stone" -> "block/stone". Anything in another namespace is
// left alone: this build only knows the minecraft namespace.
fn jc_no_ns(s: const u8[:]) -> const u8[:] {
    let ns = "minecraft:";
    if s.len > ns.len && jc_starts_with(s, ns) { return s[ns.len ..]; }
    return s;
}

fn jc_tmp_text() -> const u8[:] { return jc_tmp[..] }

// Extracts an entry into jc_tmp; returns the bytes, or an empty slice on error.
fn jc_extract(entry: i64) -> const u8[:] {
    jc_tmp = [];
    let ok, err = zip_extract(jc_jar[..], entry, jc_tmp);
    if !ok {
        jc_problem(err);
        return jc_tmp[0..0];
    }
    return jc_tmp[..];
}

fn jc_models_path(name: const u8[:], out: u8[>..]&) {
    out = [];
    let head = "assets/minecraft/models/";
    for i in head.len { out.push(head[i]); }
    for i in name.len { out.push(name[i]); }
    let tail = ".json";
    for i in tail.len { out.push(tail[i]); }
}

fn jc_textures_path(name: const u8[:], out: u8[>..]&) {
    out = [];
    let head = "assets/minecraft/textures/";
    for i in head.len { out.push(head[i]); }
    for i in name.len { out.push(name[i]); }
    let tail = ".png";
    for i in tail.len { out.push(tail[i]); }
}

fn jc_known_builtin(name: const u8[:]) -> bool {
    if eq_bytes(name, "builtin/entity") { return true; }
    if eq_bytes(name, "builtin/generated") { return true; }
    if eq_bytes(name, "builtin/missing") { return true; }
    return false;
}

fn jc_check_model_exists(name: const u8[:], where: const u8[:]) -> bool {
    let clean = jc_no_ns(name);
    jc_models_path(clean, jc_path);
    if jc_find(jc_path[..]) >= 0 { return true; }
    jc_problem(where);
    return false;
}

// A texture variable, resolved the way the client resolves it: look for the
// name in this model's textures, follow "#" references, and when the name is not
// here at all, ask the parent — a child model is allowed to inherit every
// texture it does not define. Returns 0 when it ends at a PNG that exists, 1 when
// the name resolves nowhere, 2 when it names a PNG that is not in the jar.
//
// This re-parses the chain from the jar on every call, because parsing a parent
// would otherwise wipe the caller's parsed tree (the JSON arena is shared). The
// chains are short: 16 hops is a hard stop, not an expectation.
recursive fn jc_var_chain(entry: i64, off: i64, len: i64, hops: i64) -> i64 {
    if hops > 16 { return 1; }
    let text = jc_extract(entry);
    if text.len == 0 { return 1; }
    let root = json_parse(text);
    if root < 0 { return 1; }

    // Nothing that points into json_bytes may be live across the recursion
    // below, so each branch decides first and recurses afterwards.
    var hop_off: i64 = -1;
    var hop_len: i64 = 0;
    var decided = false;
    var result: i64 = 1;
    let t = json_get(root, "textures");
    if t >= 0 && json_kind(t) == J_OBJ {
        let v = json_get(t, jc_vars[off .. off + len]);
        if v >= 0 && json_kind(v) == J_STR {
            {
                let sv = json_str(v);
                if sv.len == 0 {
                    decided = true;
                    result = 1;
                } else if sv[0] == 35 {
                    hop_len = sv.len - 1;
                    hop_off = jc_pin(sv[1 ..]);
                } else {
                    decided = true;
                    jc_textures_path(jc_no_ns(sv), jc_path);
                    if jc_find(jc_path[..]) >= 0 { result = 0; } else { result = 2; }
                }
            }
        }
    }
    if hop_off >= 0 { return jc_var_chain(entry, hop_off, hop_len, hops + 1); }
    if decided { return result; }

    var parent_entry: i64 = -1;
    {
        let parent = json_get(root, "parent");
        if parent >= 0 && json_kind(parent) == J_STR {
            let pn = jc_no_ns(json_str(parent));
            if !jc_known_builtin(pn) {
                jc_models_path(pn, jc_path);
                parent_entry = jc_find(jc_path[..]);
            }
        }
    }
    if parent_entry >= 0 { return jc_var_chain(parent_entry, off, len, hops + 1); }
    return 1;
}

// Copies a name into jc_vars (which is only ever appended to) and returns its
// offset there, so a name survives the parse of another model.
fn jc_pin(name: const u8[:]) -> i64 {
    let off = jc_vars.len;
    for i in name.len { jc_vars.push(name[i]); }
    return off;
}

fn jc_note_var(name: const u8[:]) {
    jc_var_refs += 1;
    let off = jc_pin(name);
    jc_var_spans.push(Sref { off: off, len: name.len });
}

// One model's worth of checks. `where` names the file for the problem log.
fn jc_check_model(entry: i64) {
    jc_set_file(zip_name_of(zip_entries[entry]));
    let text = jc_extract(entry);
    if text.len == 0 { return; }
    let root = json_parse(text);
    if root < 0 {
        jc_problem(json_error());
        return;
    }
    if json_kind(root) != J_OBJ {
        jc_problem("a model file whose root is not an object");
        return;
    }

    let parent = json_get(root, "parent");
    if parent >= 0 {
        if json_kind(parent) != J_STR {
            jc_problem("a parent that is not a string");
        } else {
            let p = jc_no_ns(json_str(parent));
            if jc_known_builtin(p) {
                jc_builtin_parents += 1;
            } else {
                jc_models_path(p, jc_path);
                if jc_find(jc_path[..]) >= 0 {
                    jc_parents += 1;
                } else {
                    jc_problem("a parent model that does not exist");
                }
            }
        }
    }

    // Names that are themselves "#var" are collected now and resolved after the
    // model's tree is no longer needed, since resolving parses other models.
    jc_var_spans = [];
    let textures = json_get(root, "textures");
    if textures >= 0 {
        if json_kind(textures) != J_OBJ {
            jc_problem("a textures field that is not an object");
        } else {
            var c = json_first(textures);
            while c >= 0 {
                if json_kind(c) != J_STR {
                    jc_problem("a texture that is not a string");
                } else {
                    let v = json_str(c);
                    if v.len == 0 {
                        jc_problem("an empty texture name");
                    } else if v[0] == 35 {
                        jc_note_var(json_key(c));
                    } else {
                        jc_tex_refs += 1;
                        jc_textures_path(jc_no_ns(v), jc_path);
                        if jc_find(jc_path[..]) < 0 { jc_problem("a texture file that does not exist"); }
                    }
                }
                c = json_next(c);
            }
        }
    }

    let elements = json_get(root, "elements");
    if elements >= 0 {
        if json_kind(elements) != J_ARR {
            jc_problem("an elements field that is not an array");
        } else {
            var el = json_first(elements);
            while el >= 0 {
                jc_elements += 1;
                jc_check_box(el);
                el = json_next(el);
            }
        }
    }

    // The model's tree is no longer needed: resolve the variables it defers.
    for k in jc_var_spans.len {
        let sp = jc_var_spans[k];
        let r = jc_var_chain(entry, sp.off, sp.len, 0);
        if r == 1 { jc_problem("a texture variable that resolves nowhere"); }
        else if r == 2 { jc_problem("a variable that names a missing texture file"); }
    }
}

// from/to must be three-number arrays with from <= to on every axis, and every
// face must carry four UV numbers.
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
    for axis in 3 {
        if json_num(json_at(from, axis)) > json_num(json_at(to, axis)) {
            jc_problem("a box with from > to on an axis");
        }
    }
    let rotation = json_get(el, "rotation");
    if rotation >= 0 && json_kind(rotation) != J_OBJ {
        jc_problem("a rotation that is not an object");
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
        let uv = json_get(f, "uv");
        if uv >= 0 {
            if json_kind(uv) != J_ARR || json_child_count(uv) != 4 {
                jc_problem("a face whose uv is not four numbers");
            } else {
                jc_uv_ok += 1;
            }
        } else {
            // No uv: the game derives it from the box. Legal.
            jc_uv_ok += 1;
        }
        let tex = json_get(f, "texture");
        if tex < 0 {
            jc_problem("a face without a texture key");
        } else if json_kind(tex) != J_STR || json_str(tex).len == 0 || json_str(tex)[0] != 35 {
            jc_problem("a face texture key that is not #name");
        }
        f = json_next(f);
    }
}

// A blockstate's model references: variants[*][.model] and
// multipart[*].apply[.model].
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
    if variants >= 0 {
        if json_kind(variants) != J_OBJ {
            jc_problem("a variants field that is not an object");
        } else {
            var v = json_first(variants);
            while v >= 0 {
                jc_refs_in(v, "a variant");
                v = json_next(v);
            }
        }
    }
    let multipart = json_get(root, "multipart");
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
                    jc_refs_in(apply, "a multipart apply");
                }
                m = json_next(m);
            }
        }
    }
    if variants < 0 && multipart < 0 {
        jc_problem("a blockstate with neither variants nor multipart");
    }
}

// One variant value (or one apply): a single {model:...} object, or an array of
// weighted entries.
fn jc_refs_in(node: i64, where: const u8[:]) {
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
        jc_problem(where);
    }
}

fn jc_ref_one(obj: i64) {
    let model = json_get(obj, "model");
    if model < 0 || json_kind(model) != J_STR {
        jc_problem("a variant without a model name");
        return;
    }
    jc_model_refs += 1;
    if !jc_check_model_exists(json_str(model), "a blockstate referencing a model that does not exist") {
        return;
    }
    // The x/y/uvlock fields must be numbers when present.
    let rx = json_get(obj, "x");
    if rx >= 0 && json_kind(rx) != J_NUM { jc_problem("a rotation that is not a number"); }
    let ry = json_get(obj, "y");
    if ry >= 0 && json_kind(ry) != J_NUM { jc_problem("a rotation that is not a number"); }
    let lock = json_get(obj, "uvlock");
    if lock >= 0 && json_kind(lock) != J_BOOL { jc_problem("a uvlock that is not a boolean"); }
}

fn jc_summary(name: const u8[:], count: i64) {
    print("jar: ", name, " ", count);
}

// A C host needs at least one export; this names the tool.
export fn umbra_jarcheck_tool() -> const u8[:] { return "umbra-jarcheck" }

fn main() {
    // The zip layer verifies CRCs on extraction, so its table must exist before
    // the first entry is pulled out.
    crc32_init();
    let n = arg_count();
    if n < 2 {
        jc_fail("usage: umbra_jarcheck <client.jar>");
        return;
    }
    var path: u8[>..] = [];
    arg(1, path);
    let ok = read_file(path[..], jc_jar);
    if !ok || jc_jar.len < 22 {
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

    // Pass 1: classify every entry.
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
    jc_summary("blockstates", jc_blocks);
    jc_summary("models", jc_models);
    jc_summary("textures", jc_textures);

    // Sanity floors: a jar this empty is not the game.
    if jc_blocks < 500 { jc_problem("fewer than 500 blockstates"); }
    if jc_models < 1000 { jc_problem("fewer than 1000 models"); }
    if jc_textures < 500 { jc_problem("fewer than 500 textures"); }

    // Pass 2: blockstates.
    for i in block_entries.len {
        jc_check_blockstate(block_entries[i]);
        if i % 500 == 0 { print("jar: blockstates ", i, "/", block_entries.len); }
    }

    // Pass 3: models (parents, textures, boxes).
    for i in model_entries.len {
        jc_check_model(model_entries[i]);
        if i % 1000 == 0 { print("jar: models ", i, "/", model_entries.len); }
    }

    // Pass 4: a sample of textures, decoded to prove they are real PNGs of a
    // sane size. Every 25th block texture: enough to catch a broken atlas source
    // without spending the whole run in the decoder.
    var decoded: i64 = 0;
    var square: i64 = 0;
    var step = 25;
    var t: i64 = 0;
    while t < texture_entries.len {
        jc_set_file(zip_name_of(zip_entries[texture_entries[t]]));
        let bytes = jc_extract(texture_entries[t]);
        if bytes.len > 0 {
            var palette: u8[>..] = [];
            var rgba: u8[>..] = [];
            let info, good, perr = png_decode(bytes, palette, rgba);
            if good {
                decoded += 1;
                if info.width == info.height && info.width >= 16 && info.width <= 256 { square += 1; }
                else { jc_problem("a texture that is not square or is an odd size"); }
            } else {
                jc_problem(perr);
            }
        }
        t += step;
        jc_tmp = [];
    }

    print("jar: model references ", jc_model_refs, ", parents resolved ", jc_parents,
          ", builtin parents ", jc_builtin_parents);
    print("jar: texture references ", jc_tex_refs, ", variables ", jc_var_refs);
    print("jar: boxes ", jc_elements, ", faces ", jc_faces, ", faces with four UVs ", jc_uv_ok);
    print("jar: multipart blockstates ", jc_multipart, ", weighted variants ", jc_weighted);
    print("jar: textures decoded ", decoded, ", square and 16..256 px ", square);
    print("jar: problems ", jc_problem_count);
    if jc_reported > 0 {
        print("jar: first problems", jc_problems[..]);
    }
    if jc_problem_count > 0 {
        print("FAILED: ", jc_problem_count, " problems in the jar's model data");
        exit(1);
    }
    print("PASS: the jar's model data is self-consistent (",
          jc_blocks, " blockstates, ", jc_models, " models, ", jc_textures, " textures, ",
          jc_elements, " boxes, ", jc_faces, " faces)");
}
