// Umbra core: a pack built from the client jar - every block model, every
// blockstate, and an atlas decoded from the jar's own PNGs.
//
// This is the piece that turns "the jar's data is readable" into "the jar's data is
// what the renderer draws". Nothing here is committed, shipped or published: the jar
// is downloaded at test time (tools/fetch_jar.sh) and the pack lives in memory.
//
// Model chains
// ------------
// A block model may have a `parent`, and the client merges the chain: the child's
// `textures` override the parent's, and the elements come from the first model in the
// chain that has any. Goose parses one JSON document at a time, so the chain is walked
// twice: once to collect the paths and find the model with elements, then from the
// root down to insert texture definitions in the right order (so a child wins), and
// once more to build the model that owns the elements.

import std;
import core.mem;
import core.zip;
import core.png;
import core.json;
import core.models;
import core.modelstore;
import core.atlas;

var jp_jar: u8[>..] = [];
var jp_zip: i64 = -1;
var jp_buf: u8[>..] = [];        // one extracted entry, reused
var jp_rgba: u8[>..] = [];       // one decoded PNG, reused
var jp_pal: u8[>..] = [];        // palette for indexed PNGs
var jp_pool: u8[>..] = [];       // model paths
var jp_off: i64[>..] = [];
var jp_len: i64[>..] = [];

// Counters, all printed by the caller: a pack that silently skips a model is worse
// than one that refuses it loudly.
var jp_models: i64 = 0;
var jp_models_refused: i64 = 0;
var jp_bs: i64 = 0;
var jp_bs_refused: i64 = 0;
var jp_faces: i64 = 0;
var jp_tex_used: i64 = 0;
var jp_tex_decoded: i64 = 0;
var jp_tex_missing: i64 = 0;
var jp_tex_animated: i64 = 0;
var jp_tex_scaled: i64 = 0;
var jp_err: u8[>..] = [];
var jp_worst: u8[>..] = [];

fn jp_error() -> const u8[:] { return jp_err }
fn jp_worst_case() -> const u8[:] { return jp_worst }

fn jp_fail(msg: const u8[:]) {
    jp_err = [];
    format(jp_err, msg);
}

fn jp_reset() {
    jp_jar = []; jp_zip = -1; jp_buf = []; jp_rgba = []; jp_pal = [];
    jp_pool = []; jp_off = []; jp_len = [];
    jp_models = 0; jp_models_refused = 0; jp_bs = 0; jp_bs_refused = 0;
    jp_faces = 0; jp_tex_used = 0; jp_tex_decoded = 0; jp_tex_missing = 0;
    jp_tex_animated = 0; jp_tex_scaled = 0;
    jp_err = []; jp_worst = [];
}

fn jp_path_str(s: const u8[:]) -> i64 {
    jp_off.push(jp_pool.len);
    for b in s { jp_pool.push(b); }
    jp_len.push(s.len as i64);
    return jp_off.len - 1;
}

fn jp_pool_get(i: i64) -> const u8[:] {
    return jp_pool[jp_off[i] .. jp_off[i] + jp_len[i]]
}

// Opens the jar. `crc32_init` must already have run, because the zip layer checks
// every entry it extracts.
fn jp_open(data: const u8[:]) -> bool {
    jp_jar = [];
    for b in data { jp_jar.push(b); }
    zip_reset();
    let ok, err = zip_open("client.jar", jp_jar[..]);
    if !ok {
        jp_fail(err);
        return false;
    }
    jp_zip = zip_archives.len - 1;
    return true;
}

fn jp_entries() -> i64 { return zip_count(jp_zip); }
fn jp_entry_name(k: i64) -> const u8[:] {
    return zip_name_of(zip_entries[zip_entry_at(jp_zip, k)])
}

// The bytes of one entry, or an empty slice. The buffer is reused, so a caller that
// needs two entries at once must copy.
fn jp_read(name: const u8[:]) -> const u8[:] {
    let idx = zip_find(jp_zip, name);
    if idx < 0 { return jp_buf[0..0]; }
    jp_buf = [];
    let ok, err = zip_extract(jp_jar[..], idx, jp_buf);
    if !ok {
        jp_fail(err);
        return jp_buf[0..0];
    }
    return jp_buf[..];
}

fn jp_has(name: const u8[:]) -> bool { return zip_find(jp_zip, name) >= 0; }

// "minecraft:block/oak_slab" -> "assets/minecraft/models/block/oak_slab.json"
fn jp_model_entry(path: const u8[:], out: u8[>..]&) {
    out = [];
    out.append("assets/minecraft/models/");
    var p = path;
    if starts_with(p, "minecraft:") { p = p[10..]; }
    for b in p { out.push(b); }
    out.append(".json");
}

// "minecraft:block/oak_planks" -> "assets/minecraft/textures/block/oak_planks.png"
fn jp_texture_entry(path: const u8[:], out: u8[>..]&) {
    out = [];
    out.append("assets/minecraft/textures/");
    var p = path;
    if starts_with(p, "minecraft:") { p = p[10..]; }
    for b in p { out.push(b); }
    out.append(".png");
}

// --- models --------------------------------------------------------------

// Builds one model, walking its parent chain. Returns the model index in the store,
// or -1.
fn jp_build_model(path: const u8[:]) -> i64 {
    let existing = ms_model_find(path);
    if existing >= 0 { return existing; }
    // Pass 1: the chain, and which link owns the elements.
    var chain: i64[>..] = [];
    var elements_link: i64 = -1;
    // The current link always lives in our own pool, never in a slice of the entry
    // buffer: jp_read reuses that buffer, and holding a slice across a read is the
    // kind of bug the compiler refuses to let through (and it is right).
    var cur_link = jp_path_str(path);
    var depth = 0;
    while depth < 16 {
        chain.push(cur_link);
        var entry: u8[>..] = [];
        jp_model_entry(jp_pool_get(cur_link), entry);
        let bytes = jp_read(entry[..]);
        if bytes.len == 0 { break; }
        let root = json_parse(bytes);
        if !json_valid(root) { break; }
        if elements_link < 0 && json_is(json_get(root, "elements"), J_ARR) {
            elements_link = cur_link;
        }
        var parent: u8[>..] = [];
        let ps = json_get_str(root, "parent");
        if ps.len == 0 { break; }
        for b in ps { parent.push(b); }
        cur_link = jp_path_str(parent[..]);
        depth += 1;
    }
    if chain.len == 0 { return -1; }
    // Pass 2: textures from the root down, so a child's entry overwrites its parent's.
    ms_tex_reset();
    var k = chain.len;
    while k > 0 {
        k -= 1;
        var entry: u8[>..] = [];
        jp_model_entry(jp_pool_get(chain[k]), entry);
        let bytes = jp_read(entry[..]);
        if bytes.len == 0 { continue; }
        let root = json_parse(bytes);
        if !json_valid(root) { continue; }
        let tex = json_get(root, "textures");
        if json_is(tex, J_OBJ) {
            var t = json_first(tex);
            while t >= 0 {
                if json_is(t, J_STR) { ms_tex_put(json_key(t), json_str(t)); }
                t = json_next(t);
            }
        }
    }
    // Pass 3: build the link that owns the elements.
    var entry: u8[>..] = [];
    if elements_link >= 0 {
        jp_model_entry(jp_pool_get(elements_link), entry);
    } else {
        jp_model_entry(path, entry);
    }
    let bytes = jp_read(entry[..]);
    if bytes.len == 0 { return -1; }
    let root = json_parse(bytes);
    if !json_valid(root) { return -1; }
    let m = ms_build(path, root);
    if m < 0 {
        jp_models_refused += 1;
        if jp_models_refused <= 3 { jp_worst = []; format(jp_worst, path); }
        return -1;
    }
    jp_models += 1;
    jp_faces += ms_face_count(m);
    return m;
}

// Builds every model the jar has under models/block and models/item. Item models are
// included because a held block and a dropped one are item models; they cost a few
// hundred faces and nothing else.
fn jp_build_models() -> i64 {
    let n = jp_entries();
    var built: i64 = 0;
    for k in n {
        let name = jp_entry_name(k);
        if !starts_with(name, "assets/minecraft/models/") { continue; }
        if !ends_with(name, ".json") { continue; }
        // "assets/minecraft/models/block/oak_slab.json" -> "minecraft:block/oak_slab"
        // (the prefix is 24 bytes and ".json" is 5, counted here rather than guessed)
        var path: u8[>..] = [];
        path.append("minecraft:");
        for b in name[24..name.len - 5] { path.push(b); }
        if jp_build_model(path[..]) >= 0 { built += 1; }
    }
    return built;
}

// --- blockstates --------------------------------------------------------

fn jp_build_blockstate(name: const u8[:]) -> i64 {
    var entry: u8[>..] = [];
    entry.append("assets/minecraft/blockstates/");
    for b in name { entry.push(b); }
    entry.append(".json");
    let bytes = jp_read(entry[..]);
    if bytes.len == 0 { return -1; }
    let root = json_parse(bytes);
    if !json_valid(root) { return -1; }
    var full: u8[>..] = [];
    full.append("minecraft:");
    for b in name { full.push(b); }
    let bs = ms_bs_build(full[..], root);
    if bs < 0 { jp_bs_refused += 1; return -1; }
    jp_bs += 1;
    return bs;
}

fn jp_build_blockstates() -> i64 {
    let n = jp_entries();
    var built: i64 = 0;
    for k in n {
        let name = jp_entry_name(k);
        if !starts_with(name, "assets/minecraft/blockstates/") { continue; }
        if !ends_with(name, ".json") { continue; }
        // 29 bytes of "assets/minecraft/blockstates/"
        var short: u8[>..] = [];
        for b in name[29..name.len - 5] { short.push(b); }
        if jp_build_blockstate(short[..]) >= 0 { built += 1; }
    }
    return built;
}

// --- the atlas -----------------------------------------------------------

var jp_atlas: u8[>..] = [];
var jp_layout: AtlasLayout = AtlasLayout {
    tile: 16, gutter: 2, cols: 1, rows: 1, width: 16, height: 16, cells: 1,
};
var jp_slot: i64[>..] = [];      // texture path index -> atlas slot
var jp_atlas_hash: u32 = 0;

fn jp_atlas_pixels() -> const u8[:] { return jp_atlas }
fn jp_atlas_layout() -> AtlasLayout { return jp_layout }
fn jp_atlas_of_hash() -> u32 { return jp_atlas_hash }
fn jp_slot_of(path_index: i64) -> i64 {
    if path_index < 0 || path_index >= jp_slot.len { return 0; }
    return jp_slot[path_index];
}
fn jp_texture_missing() -> i64 { return jp_tex_missing; }
fn jp_texture_decoded() -> i64 { return jp_tex_decoded; }
fn jp_texture_animated() -> i64 { return jp_tex_animated; }

// Packs every texture the models reference, in path order, with slot 0 reserved for
// the missing tile. Decodes each PNG, takes frame 0 of an animation, scales anything
// that is not already 16x16 (nearest neighbour, so no colour is invented), and
// replicates each tile's edge into its gutter so a mip level cannot bleed.
fn jp_build_atlas(tile_px: i64, gutter: i64) -> bool {
    let paths = ms_path_count();
    // Count the paths that at least one face uses, so the atlas is not sized for
    // every texture the jar has.
    var used: i64[>..] = [];
    for p in paths {
        for f in msf_tex.len {
            if msf_tex[f] == p { used.push(p); break; }
        }
    }
    jp_tex_used = used.len as i64;
    jp_layout = atlas_plan(used.len + 1, tile_px, gutter);
    jp_atlas = [];
    for i in jp_layout.width * jp_layout.height * 4 { jp_atlas.push(0); }
    jp_slot = [];
    for p in paths { jp_slot.push(-1); }
    // Slot 0 is always the loud missing tile.
    atlas_write_missing(jp_atlas, jp_layout, 0);
    atlas_replicate_gutter(jp_atlas, jp_layout, 0);

    var slot: i64 = 1;
    for u in used.len {
        let p = used[u];
        jp_slot[p] = slot;
        var entry: u8[>..] = [];
        jp_texture_entry(ms_path(p), entry);
        let bytes = jp_read(entry[..]);
        if bytes.len == 0 {
            jp_tex_missing += 1;
            atlas_write_missing(jp_atlas, jp_layout, slot);
            atlas_replicate_gutter(jp_atlas, jp_layout, slot);
            slot += 1;
            continue;
        }
        jp_pal = [];
        jp_rgba = [];
        let info, ok, perr = png_decode(bytes, jp_pal, jp_rgba);
        if !ok {
            jp_tex_missing += 1;
            atlas_write_missing(jp_atlas, jp_layout, slot);
            atlas_replicate_gutter(jp_atlas, jp_layout, slot);
            slot += 1;
            continue;
        }
        var frame0 = false;
        if info.height > info.width && info.height % info.width == 0 { frame0 = true; jp_tex_animated += 1; }
        if info.width != tile_px || (frame0 == false && info.height != tile_px) ||
           (frame0 == true && info.width != tile_px) {
            jp_tex_scaled += 1;
        }
        atlas_write_tile(jp_atlas, jp_layout, slot, jp_rgba[..], info.width, info.height, frame0);
        atlas_replicate_gutter(jp_atlas, jp_layout, slot);
        jp_tex_decoded += 1;
        slot += 1;
    }
    jp_atlas_hash = atlas_hash(jp_atlas);
    return true;
}

// --- colormaps -----------------------------------------------------------

// The jar's grass and foliage colormaps are 256x256: x is temperature, y is
// (1 - humidity). Water is a flat colour in newer versions, but the same map exists.
// The sample point is vanilla's "plains": temperature 0.8, humidity 0.4.
var jp_cmap_ok: bool = false;
var jp_cmap_w: i64 = 0;
var jp_cmap_h: i64 = 0;
var jp_cmap_px: u8[>..] = [];

fn jp_read_colormap(name: const u8[:]) -> bool {
    var entry: u8[>..] = [];
    entry.append("assets/minecraft/textures/colormap/");
    for b in name { entry.push(b); }
    entry.append(".png");
    let bytes = jp_read(entry[..]);
    if bytes.len == 0 { return false; }
    jp_pal = [];
    jp_cmap_px = [];
    let info, ok, perr = png_decode(bytes, jp_pal, jp_cmap_px);
    if !ok || info.width < 2 || info.height < 2 { return false; }
    jp_cmap_w = info.width;
    jp_cmap_h = info.height;
    jp_cmap_ok = true;
    return true;
}

// The RGB at the plains sample point, as 0..1 floats.
fn jp_colormap_color(u: f32, v: f32, out: f32[3]&) {
    out[0] = 1.0; out[1] = 1.0; out[2] = 1.0;
    if !jp_cmap_ok { return; }
    var x = (u * (jp_cmap_w as f32)) as i64;
    var y = (v * (jp_cmap_h as f32)) as i64;
    if x < 0 { x = 0; }
    if y < 0 { y = 0; }
    if x >= jp_cmap_w { x = jp_cmap_w - 1; }
    if y >= jp_cmap_h { y = jp_cmap_h - 1; }
    let i = (y * jp_cmap_w + x) * 4;
    if i + 3 >= jp_cmap_px.len { return; }
    out[0] = (jp_cmap_px[i] as f32) / 255.0;
    out[1] = (jp_cmap_px[i + 1] as f32) / 255.0;
    out[2] = (jp_cmap_px[i + 2] as f32) / 255.0;
}
