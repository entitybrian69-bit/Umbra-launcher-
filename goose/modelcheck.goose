// Umbra model check: every block model in the official client jar, parsed by the
// parser the mesher actually uses (core/models.goose).
//
// This is the counterpart of jarcheck: jarcheck asks "can the client draw what a
// blockstate names", walking parents and resolving textures to PNGs; this asks the
// narrower question "does the geometry parser accept every model in the jar, and
// what does it find in them". Two parsers that agree on the real data is the point;
// the counts here are what the model path is built on.
//
//   umbra_modelcheck <client.jar>

import std;
import os;
import core.mem;
import core.zip;
import core.models;

var mc_jar: u8[>..] = [];
var mc_bytes: i64 = 0;
var mc_buf: u8[>..] = [];      // one extracted model, reused

fn mc_count(s: const u8[:], head: const u8[:]) -> bool {
    if s.len < head.len { return false; }
    return eq_bytes(s[..head.len], head);
}

fn mc_tail(s: const u8[:], tail: const u8[:]) -> bool {
    if s.len < tail.len { return false; }
    return eq_bytes(s[s.len - tail.len..], tail);
}

fn mc_fail(msg: const u8[:]) {
    print("FAIL: ", msg, "\n");
    exit(1);
}

fn main() {
    crc32_init();
    if arg_count() < 2 {
        print("usage: umbra_modelcheck <client.jar>\n");
        exit(2);
    }
    var path: u8[>..] = [];
    arg(1, path);
    if !read_file(path[..], mc_jar) || mc_jar.len < 22 {
        mc_fail("the jar could not be read");
    }
    // A minimum model count keeps the check from passing on something that is not a
    // client jar; the fake jar the unit check uses is tiny, so it passes a smaller
    // number on the command line.
    var min_models: i64 = 100;
    if arg_count() >= 3 {
        var m: u8[>..] = [];
        arg(2, m);
        var v: i64 = 0;
        for i in m.len {
            let d = (m[i] as i64) - 48;
            if d < 0 || d > 9 { v = -1; }
            if v >= 0 { v = v * 10 + d; }
        }
        if v > 0 { min_models = v; }
    }
    mc_bytes = mc_jar.len as i64;
    zip_reset();
    let opened, perr = zip_open("client.jar", mc_jar[..]);
    if !opened {
        print("model: not a zip: ", perr, "\n");
        exit(1);
    }
    let arch = zip_archives.len - 1;
    let n = zip_count(arch);
    var models = 0;
    var elements = 0;
    var faces = 0;
    var with_uv = 0;
    var with_cull = 0;
    var with_tint = 0;
    var rotated = 0;
    var refused = 0;
    var templates = 0;
    var biggest = 0;
    for i in n {
        let idx = zip_entry_at(arch, i);
        let name = zip_name_of(zip_entries[idx]);
        if !mc_count(name, "assets/minecraft/models/") { continue; }
        if !mc_tail(name, ".json") { continue; }
        mc_buf = [];
        let ok, xerr = zip_extract(mc_jar[..], idx, mc_buf);
        if !ok { continue; }
        models += 1;
        if (mc_buf.len as i64) > biggest { biggest = mc_buf.len as i64; }
        mdl_reset();
        let ne = mdl_parse(mc_buf[..]);
        if ne < 0 {
            refused += 1;
            if refused <= 5 {
                print("model: refused ", name, ": ", mdl_error_text());
            }
            continue;
        }
        if ne == 0 { templates += 1; }
        elements += ne;
        let s = mdl_stats();
        faces += s.faces;
        with_uv += s.with_uv;
        with_cull += s.with_cull;
        with_tint += s.with_tint;
        rotated += s.rotated;
    }
    print("model: ", mc_bytes, " bytes in the jar, ", n, " entries\n");
    print("model: ", models, " block models parsed, ", refused, " refused\n");
    print("model: ", elements, " elements, ", faces, " faces\n");
    print("model: ", with_uv, " faces with an explicit uv, ", with_cull,
          " with a cullface, ", with_tint, " with a tint index, ", rotated, " rotated\n");
    print("model: ", templates, " models are templates with no elements of their own\n");
    print("model: largest model is ", biggest, " bytes of JSON\n");
    if refused > 0 {
        print("FAILED: ", refused, " jar models were refused by the parser\n");
        exit(1);
    }
    if models < min_models {
        print("FAILED: only ", models, " models found, wanted at least ", min_models, "\n");
        exit(1);
    }
    print("PASS: every block model in the jar parses\n");
}
