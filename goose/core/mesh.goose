// Umbra core: chunk section meshing.
//
// Turns one chunk column's blocks into triangles with positions, normals,
// atlas UVs, tint and baked ambient occlusion. Faces between two opaque blocks
// are dropped, which is where most of the speed comes from; the rest is one
// pass over 4096 blocks per section with no allocation (the vertex and index
// arenas are grow arrays reused every call).

import std;
import core.mem;
import core.region;
import core.textures;
import core.models;
import core.modelstore;

// The vertex layout the GPU consumes. Packed, in declaration order; the C side
// mirrors it in platform/shared/umbra_vertex.h.
struct Vertex {
    x: f32, y: f32, z: f32,
    nx: f32, ny: f32, nz: f32,
    u: f32, v: f32,
    r: f32, g: f32, b: f32,
    ao: f32,
}

// Block render class, from the jar's block models later; for now from the
// block name, which the registry already has.
let RC_AIR = 0;
let RC_OPAQUE = 1;
let RC_CUTOUT = 2;      // leaves, plants: opaque test for culling, alpha test
let RC_TRANSLUCENT = 3; // water, glass: no culling, blended
let RC_CROSS = 4;       // flowers, saplings: two crossed quads

fn render_class(id: u32) -> i64 {
    if id == 0 { return RC_AIR; }
    let name = bs_name(id);
    if name.len == 0 { return RC_OPAQUE; }
    let path = bs_path(name);
    // Water and glass are translucent; leaves and plants are cutout.
    if eq_bytes(path, "water") || eq_bytes(path, "glass") || eq_bytes(path, "ice") ||
       eq_bytes(path, "lava") {
        return RC_TRANSLUCENT;
    }
    if eq_bytes(path, "short_grass") || eq_bytes(path, "grass") ||
       eq_bytes(path, "fern") || eq_bytes(path, "dandelion") ||
       eq_bytes(path, "poppy") || eq_bytes(path, "sapling") ||
       eq_bytes(path, "dead_bush") || eq_bytes(path, "torch") {
        return RC_CROSS;
    }
    if ends_with(path, "_leaves") || ends_with(path, "_sapling") || ends_with(path, "_plant") {
        return RC_CUTOUT;
    }
    return RC_OPAQUE;
}

fn is_solid(id: u32) -> bool {
    let rc = render_class(id);
    return rc == RC_OPAQUE || rc == RC_CUTOUT;
}

// --- geometry -----------------------------------------------------------

// Face order: 0 -Y, 1 +Y, 2 -Z, 3 +Z, 4 -X, 5 +X.
// Flat tables: normals are 6*3 floats, corners 6*4*3, indexed face*(...) + ...
var face_normals: f32[18] = [
    0.0, -1.0, 0.0,   0.0, 1.0, 0.0,
    0.0, 0.0, -1.0,   0.0, 0.0, 1.0,
    -1.0, 0.0, 0.0,   1.0, 0.0, 0.0,
];

// Four corners per face, counter-clockwise seen from outside the block,
// in blocks of 0..1.
var face_corners: f32[72] = [
    // -Y. Wound counter-clockwise seen from below (from outside the block): the
    // host suite checks every triangle's cross product against its normal, and it
    // caught both horizontal faces wound the other way -- which culling would
    // have drawn as a world with no top and no bottom.
    0.0, 0.0, 0.0,  1.0, 0.0, 0.0,  1.0, 0.0, 1.0,  0.0, 0.0, 1.0,
    // +Y
    0.0, 1.0, 0.0,  0.0, 1.0, 1.0,  1.0, 1.0, 1.0,  1.0, 1.0, 0.0,
    // -Z
    0.0, 0.0, 0.0,  0.0, 1.0, 0.0,  1.0, 1.0, 0.0,  1.0, 0.0, 0.0,
    // +Z
    1.0, 0.0, 1.0,  1.0, 1.0, 1.0,  0.0, 1.0, 1.0,  0.0, 0.0, 1.0,
    // -X
    0.0, 0.0, 1.0,  0.0, 1.0, 1.0,  0.0, 1.0, 0.0,  0.0, 0.0, 0.0,
    // +X
    1.0, 0.0, 0.0,  1.0, 1.0, 0.0,  1.0, 1.0, 1.0,  1.0, 0.0, 1.0,
];

fn face_normal(face: i64, axis: i64) -> f32 { return face_normals[face * 3 + axis]; }
fn face_corner(face: i64, corner: i64, axis: i64) -> f32 {
    return face_corners[face * 12 + corner * 3 + axis];
}

// A block whose geometry comes from a parsed model instead of a whole cube. The
// demo world uses this for one shape (a slab) to exercise the model path end to
// end; the loader stage binds the jar's own models here.
var model_block: u32 = 0;
var model_bound: bool = false;
var model_faces_drawn: i64 = 0;

fn mesh_bind_model(id: u32) {
    model_block = id;
    model_bound = true;
}

fn mesh_model_faces() -> i64 { return model_faces_drawn; }

var mesh_verts: Vertex[>..] = [];
var mesh_indices: u32[>..] = [];
// Per-batch ranges: [start, count] in indices, in the order the renderer draws
// them: opaque, cutout, translucent.
var batch_starts: i64[3] = [0, 0, 0];
var batch_counts: i64[3] = [0, 0, 0];

fn mesh_reset() {
    mesh_verts = [];
    mesh_indices = [];
    for i in 3 {
        batch_starts[i] = 0;
        batch_counts[i] = 0;
    }
    mesh_model_blocks = 0;
    mesh_model_faces = 0;
    mesh_model_skipped = 0;
}

// Geometry only: what a caller that meshes a world column by column throws away
// between columns. The counters survive, because they are what the column added up to.
fn mesh_clear_geometry() {
    mesh_verts = [];
    mesh_indices = [];
    batch_starts = [0, 0, 0];
    batch_counts = [0, 0, 0];
}

// Vertex order to the ambient-occlusion average the game uses: the three
// neighbours the corner touches, with the diagonal weighted twice.
fn corner_ao(side1: bool, side2: bool, corner: bool) -> f32 {
    if side1 && side2 { return 0.4; }
    let n = (if side1 { 1 } else { 0 }) + (if side2 { 1 } else { 0 }) + (if corner { 1 } else { 0 });
    if n == 3 { return 1.0; }
    if n == 2 { return 0.8; }
    if n == 1 { return 0.6; }
    return 0.4;
}

fn push_quad(x0: f32, y0: f32, z0: f32, face: i64, u0: f32, v0: f32, u1: f32, v1: f32,
             tint: f32[3], ao: f32[4]) {
    let base = mesh_verts.len as u32;
    // Vanilla face shading: top full, bottom darkest, sides in between.
    let light = if face == 1 { 1.0 } else if face == 0 { 0.5 } else if face == 2 || face == 3 { 0.8 } else { 0.6 };
    for c in 4 {
        let ao_v = ao[c];
        let shade = light * ao_v;
        mesh_verts.push(Vertex {
            x: x0 + face_corner(face, c, 0), y: y0 + face_corner(face, c, 1),
            z: z0 + face_corner(face, c, 2),
            nx: face_normal(face, 0), ny: face_normal(face, 1), nz: face_normal(face, 2),
            u: if c == 0 || c == 3 { u0 } else { u1 },
            v: if c == 0 || c == 1 { v1 } else { v0 },
            r: tint[0] * shade, g: tint[1] * shade, b: tint[2] * shade,
            ao: ao_v,
        });
    }
    // Two triangles; flip the diagonal where AO would otherwise interpolate
    // across the darker pair, which is the artifact vanilla avoids.
    if ao[0] + ao[2] > ao[1] + ao[3] {
        mesh_indices.push(base);
        mesh_indices.push(base + 1);
        mesh_indices.push(base + 2);
        mesh_indices.push(base);
        mesh_indices.push(base + 2);
        mesh_indices.push(base + 3);
    } else {
        mesh_indices.push(base + 1);
        mesh_indices.push(base + 2);
        mesh_indices.push(base + 3);
        mesh_indices.push(base + 1);
        mesh_indices.push(base + 3);
        mesh_indices.push(base);
    }
}

// --- geometry from the model store ---------------------------------------
//
// A block's picture comes from its blockstate: the models the rules select, each
// with the rotation the rule asked for. The store holds every model in the jar, so
// this is not one special block any more: it is all of them.
//
// The atlas slot for a texture path is set by the caller once the atlas is packed
// (`mesh_set_tile`), and the tints come from the jar's colormaps (`mesh_set_tints`).

var mesh_store_on: bool = false;
var mesh_tile_slot: i64[>..] = [];      // path index -> atlas slot, -1 missing
var mesh_tint_grass: f32[3] = [0.55, 0.75, 0.35];
var mesh_tint_foliage: f32[3] = [0.40, 0.66, 0.22];
var mesh_tint_water: f32[3] = [0.20, 0.40, 0.90];
var mesh_model_blocks: i64 = 0;         // blocks drawn from a model
var mesh_model_faces: i64 = 0;          // faces drawn from a model
var mesh_model_skipped: i64 = 0;        // blocks whose blockstate had no model

// Blockstate index per block id, -2 = not asked yet. Without this the cullface test
// answers its "is the neighbour a full cube" question with a linear scan of every
// blockstate in the jar, for every face of every block.
var mesh_bs_cache: i64[>..] = [];

fn mesh_bs_of(id: u32) -> i64 {
    let key = id as i64;
    while mesh_bs_cache.len <= key { mesh_bs_cache.push(-2); }
    if mesh_bs_cache[key] != -2 { return mesh_bs_cache[key]; }
    let found = ms_bs_find(bs_name(id));
    mesh_bs_cache[key] = found;
    return found;
}

fn mesh_use_store() { mesh_store_on = true; }
fn mesh_store_active() -> bool { return mesh_store_on; }
fn mesh_model_block_count() -> i64 { return mesh_model_blocks; }
fn mesh_model_face_count() -> i64 { return mesh_model_faces; }
fn mesh_model_missing() -> i64 { return mesh_model_skipped; }

// Which atlas the tile rects are computed in: the placeholder atlas the app builds
// until a jar is loaded, then whatever the jar's pack laid out. The two have different
// cell sizes and cell counts, so a tile rect from the wrong one lands on another block's
// art - which looks like a texture bug and is a layout bug.
var mesh_layout: AtlasLayout = AtlasLayout {
    tile: 0, gutter: 0, cols: 1, rows: 1, width: 0, height: 0, cells: 0,
};
var mesh_layout_set: bool = false;

fn mesh_set_layout(l: AtlasLayout) {
    mesh_layout = l;
    mesh_layout_set = true;
}

fn mesh_layout_of() -> AtlasLayout {
    if mesh_layout_set { return mesh_layout; }
    return tex_layout_of();
}

fn mesh_set_tile(path_index: i64, slot: i64) {
    while mesh_tile_slot.len <= path_index { mesh_tile_slot.push(-1); }
    mesh_tile_slot[path_index] = slot;
}

fn mesh_set_tints(grass: f32[3], foliage: f32[3], water: f32[3]) {
    for k in 3 {
        mesh_tint_grass[k] = grass[k];
        mesh_tint_foliage[k] = foliage[k];
        mesh_tint_water[k] = water[k];
    }
}

fn mesh_tint_of(index: i64) -> f32[3] {
    if index == 0 { return mesh_tint_grass; }
    if index == 1 { return mesh_tint_foliage; }
    if index == 2 { return mesh_tint_water; }
    return [1.0, 1.0, 1.0];
}

// Rotate a vector about Y then X by whole quarter turns, the order the jar applies
// them in (the blockstate's `y`, then its `x`).
fn mesh_rot_vec(v: f32[3], xrot: i64, yrot: i64) -> f32[3] {
    var x = v[0];
    var y = v[1];
    var z = v[2];
    for i in (yrot / 90) % 4 {
        let nx = z;
        let nz = -x;
        x = nx;
        z = nz;
    }
    for i in (xrot / 90) % 4 {
        let ny = -z;
        let nz = y;
        y = ny;
        z = nz;
    }
    return [x, y, z];
}

// The texture coordinate a corner of a face covers, in the model's own 0..16 space,
// with the orientation the jar gives each side.
fn mesh_face_tu(face: i64, lx: f32, ly: f32, lz: f32) -> f32 {
    if face == 0 { return lx; }              // down
    if face == 1 { return lx; }              // up
    if face == 2 { return 16.0 - lx; }       // north
    if face == 3 { return lx; }              // south
    if face == 4 { return lz; }              // west
    return 16.0 - lz;                        // east
}

fn mesh_face_tv(face: i64, lx: f32, ly: f32, lz: f32) -> f32 {
    if face == 0 { return 16.0 - lz; }       // down
    if face == 1 { return lz; }              // up
    return 16.0 - ly;                        // all four sides
}

// Is the block at this cell a full cube of an opaque block? That is the only thing a
// cullface may hide behind, and it is answered from the same store the geometry
// comes from, so a slab next door never hides a face.
fn mesh_full_cube(id: u32) -> bool {
    if id == 0 { return false; }
    if render_class(id) != RC_OPAQUE { return false; }
    let bs = mesh_bs_of(id);
    if bs < 0 { return true; }   // no blockstate: the fallback cube is full
    let n = ms_select(bs, bs_props_of(id), 0);
    if n == 0 { return false; }
    // Copied for the same reason as in mesh_emit_model: nothing may hold an index into
    // the shared selection across a call that can select again.
    var rules: i64[>..] = [];
    for k in n { rules.push(ms_sel_at(k)) }
    for k in rules.len {
        let m = ms_rule_model(rules[k]);
        if m < 0 || !ms_model_full(m) { return false; }
    }
    return true;
}

// One face of one model instance, with the rule's rotation applied to its corners and
// its normal, its own uv rect, and a cullface test against the neighbour.
fn push_model_face(c: ChunkColumn&, bx: i32, by: i32, bz: i32, fi: i64, rule: i64) -> i64 {
    let face = msf_side[fi];
    let elem = msf_elem[fi];
    let xrot = ms_rule_xrot(rule);
    let yrot = ms_rule_yrot(rule);
    let tex = msf_tex[fi];
    // Cullface: only a face that names a side, on a face of the block, next to a full
    // cube, may vanish.
    if msf_cull[fi] >= 0 {
        // The cullface is the side the face looks at; after rotation it looks
        // somewhere else, and the neighbour that hides it moves with it.
        let cn = mesh_rot_vec([face_normal(msf_cull[fi], 0), face_normal(msf_cull[fi], 1),
                               face_normal(msf_cull[fi], 2)], xrot, yrot);
        let nx = bx + (cn[0] as i32);
        let ny = by + (cn[1] as i32);
        let nz = bz + (cn[2] as i32);
        if mesh_full_cube(neighbour(c, nx, ny, nz)) { return 0; }
    }
    var slot: i64 = -1;
    if tex >= 0 && tex < mesh_tile_slot.len { slot = mesh_tile_slot[tex]; }
    let t = atlas_tile(mesh_layout_of(), slot);
    let lo0 = ms_elem_lo(elem, 0); let lo1 = ms_elem_lo(elem, 1); let lo2 = ms_elem_lo(elem, 2);
    let hi0 = ms_elem_hi(elem, 0); let hi1 = ms_elem_hi(elem, 1); let hi2 = ms_elem_hi(elem, 2);
    // The uv rect, in the model's own space.
    let u0 = msf_uv[fi * 4 + 0]; let v0 = msf_uv[fi * 4 + 1];
    let u1 = msf_uv[fi * 4 + 2]; let v1 = msf_uv[fi * 4 + 3];
    let face_rot = msf_rot[fi];
    var tint: f32[3] = [1.0, 1.0, 1.0];
    if msf_tint[fi] >= 0 { tint = mesh_tint_of(msf_tint[fi]); }
    let light = if msf_shade[fi] == 0 { 1.0 } else if face == 1 { 1.0 } else if face == 0 { 0.5 } else if face == 2 || face == 3 { 0.8 } else { 0.6 };
    let norm = mesh_rot_vec([face_normal(face, 0), face_normal(face, 1), face_normal(face, 2)], xrot, yrot);
    let base = mesh_verts.len as u32;
    for corner in 4 {
        let ux = face_corner(face, corner, 0);
        let uy = face_corner(face, corner, 1);
        let uz = face_corner(face, corner, 2);
        let lx = if ux > 0.5 { hi0 } else { lo0 };
        let ly = if uy > 0.5 { hi1 } else { lo1 };
        let lz = if uz > 0.5 { hi2 } else { lo2 };
        // Texture coordinates: the corner's place in the model, mapped through the
        // face's uv rect, with the face's own rotation applied first.
        var tu = mesh_face_tu(face, lx, ly, lz);
        var tv = mesh_face_tv(face, lx, ly, lz);
        // A uv rect is given in the same 0..16 space, so a mirrored rect (16,0,0,16)
        // mirrors the texture without a separate flag: u = lerp(u0, u1, tu/16).
        var au = u0 + (tu / 16.0) * (u1 - u0);
        var av = v0 + (tv / 16.0) * (v1 - v0);
        for r in face_rot {
            // 90 degrees: (u, v) -> (v, 16-u), applied inside the rect's own 0..16 box.
            let nu = av;
            let nv = 16.0 - au;
            au = nu;
            av = nv;
        }
        let ua = t.u0 + (au / 16.0) * (t.u1 - t.u0);
        let va = t.v0 + (av / 16.0) * (t.v1 - t.v0);
        // Position: the box corner in blocks, relative to the block's centre, rotated.
        let off = mesh_rot_vec([lx / 16.0 - 0.5, ly / 16.0 - 0.5, lz / 16.0 - 0.5], xrot, yrot);
        mesh_verts.push(Vertex {
            x: (bx as f32) + 0.5 + off[0],
            y: (by as f32) + 0.5 + off[1],
            z: (bz as f32) + 0.5 + off[2],
            nx: norm[0], ny: norm[1], nz: norm[2],
            u: ua, v: va,
            r: tint[0] * light, g: tint[1] * light, b: tint[2] * light,
            ao: 1.0,
        });
    }
    mesh_indices.push(base);
    mesh_indices.push(base + 1);
    mesh_indices.push(base + 2);
    mesh_indices.push(base);
    mesh_indices.push(base + 2);
    mesh_indices.push(base + 3);
    return 1;
}

// Draws one block from its blockstate. Returns how many faces it drew; 0 means the
// blockstate had no model and the caller should fall back to a cube.
fn mesh_emit_model(c: ChunkColumn&, bx: i32, by: i32, bz: i32, id: u32) -> i64 {
    let bs = mesh_bs_of(id);
    if bs < 0 { return 0; }
    // The weighted variant is chosen by the block's own position, so a remesh picks
    // the same one.
    let hash = (bx * 3129871 + by * 116129781 + bz * 31) as i64;
    let n = ms_select(bs, bs_props_of(id), hash);
    if n == 0 { return 0; }
    // The selection lives in one shared buffer, and the cullface test below runs
    // ms_select again (mesh_full_cube) for every face: the second block of a multipart
    // state then read index 1 of a one-entry buffer and the real-world render died at
    // 5.5 million blocks with "index 1 out of bounds (length 1)". Copy it out first.
    var rules: i64[>..] = [];
    for sel in n { rules.push(ms_sel_at(sel)) }
    var drew: i64 = 0;
    for sel in rules.len {
        let rule = rules[sel];
        let m = ms_rule_model(rule);
        if m < 0 { continue; }
        let start = ms_face_start(m);
        let count = ms_face_count(m);
        for k in count {
            drew += push_model_face(c, bx, by, bz, start + k, rule);
        }
    }
    // A block whose faces were all culled is still drawn from its model: culling is
    // what the model's cullface asked for. Only a block with no model of its own counts
    // as skipped, and the caller counts that.
    mesh_model_blocks += 1;
    mesh_model_faces += drew;
    return drew;
}

// One face of a box that is not the whole block: a slab, a torch, a fence post.
// The corners come from the box and the face, so the winding rule stays in one
// place (it is the unit-cube table scaled into the box).
fn push_box_face(bx: i32, by: i32, bz: i32, face: i64, lo: f32[3], hi: f32[3],
                 uv: f32[4], tint: f32[3]) {
    let base = mesh_verts.len as u32;
    let light = if face == 1 { 1.0 } else if face == 0 { 0.5 } else if face == 2 || face == 3 { 0.8 } else { 0.6 };
    for c in 4 {
        let ux = face_corner(face, c, 0);
        let uy = face_corner(face, c, 1);
        let uz = face_corner(face, c, 2);
        let px = (bx as f32) + (if ux > 0.5 { hi[0] } else { lo[0] });
        let py = (by as f32) + (if uy > 0.5 { hi[1] } else { lo[1] });
        let pz = (bz as f32) + (if uz > 0.5 { hi[2] } else { lo[2] });
        mesh_verts.push(Vertex {
            x: px, y: py, z: pz,
            nx: face_normal(face, 0), ny: face_normal(face, 1), nz: face_normal(face, 2),
            u: if c == 0 || c == 3 { uv[0] } else { uv[2] },
            v: if c == 0 || c == 1 { uv[3] } else { uv[1] },
            r: tint[0] * light, g: tint[1] * light, b: tint[2] * light,
            ao: 1.0,
        });
    }
    mesh_indices.push(base);
    mesh_indices.push(base + 1);
    mesh_indices.push(base + 2);
    mesh_indices.push(base);
    mesh_indices.push(base + 2);
    mesh_indices.push(base + 3);
}

fn push_cross(x0: f32, y0: f32, z0: f32, tint: f32[3], uv: f32[4]) {
    // Two quads through the block's diagonals, as a plant model does.
    for d in 2 {
        let a: f32 = 0.1464;  // (1 - sqrt(2)/2) / 2, the model's inset
        let b: f32 = 0.8536;
        var x1: f32 = 0.0;
        var z1: f32 = 0.0;
        var x2: f32 = 0.0;
        var z2: f32 = 0.0;
        if d == 0 { x1 = a; z1 = a; x2 = b; z2 = b; } else { x1 = a; z1 = b; x2 = b; z2 = a; }
        let base = mesh_verts.len as u32;
        let light: f32 = 1.0;
        var cx: f32[4] = [x1, x1, x2, x2];
        var cy: f32[4] = [0.0, 1.0, 1.0, 0.0];
        var cz: f32[4] = [z1, z1, z2, z2];
        for c in 4 {
            mesh_verts.push(Vertex {
                x: x0 + cx[c], y: y0 + cy[c], z: z0 + cz[c],
                nx: 0.0, ny: 1.0, nz: 0.0,
                u: if c == 0 || c == 1 { uv[0] } else { uv[2] },
                v: if c == 0 || c == 1 { uv[3] } else { uv[1] },
                r: tint[0] * light, g: tint[1] * light, b: tint[2] * light,
                ao: 1.0,
            });
        }
        mesh_indices.push(base);
        mesh_indices.push(base + 1);
        mesh_indices.push(base + 2);
        mesh_indices.push(base);
        mesh_indices.push(base + 2);
        mesh_indices.push(base + 3);
    }
}

// Emits one block's geometry from the model currently parsed by core.models.
// Every element is a box; each of its present faces becomes a quad, with the
// model's own uv rect mapped into that texture's atlas tile, and the model's
// cullface honoured: a face that names the neighbour it faces is dropped when that
// neighbour is solid, which is the only culling a model is allowed to ask for.
fn push_model(c: ChunkColumn&, bx: i32, by: i32, bz: i32, tint: f32[3]) {
    for e in mdl_elements {
        var lo: f32[3] = [0.0, 0.0, 0.0];
        var hi: f32[3] = [0.0, 0.0, 0.0];
        mdl_elem_box(e, lo, hi);
        for face in 6 {
            let fi = e * 6 + face;
            if mdl_tex[fi] < 0 { continue; }
            // Culling: only a face on the block's surface may vanish.
            if mdl_face_cullable(e, face) {
                let nx = bx + (face_normal(face, 0) as i32);
                let ny = by + (face_normal(face, 1) as i32);
                let nz = bz + (face_normal(face, 2) as i32);
                if is_solid(neighbour(c, nx, ny, nz)) { continue; }
            }
            let slot = tex_slot_for_path(mdl_texture_name(mdl_tex[fi]));
            let t = atlas_tile(mesh_layout_of(), slot);
            var uv: f32[4] = [0.0, 0.0, 0.0, 0.0];
            mdl_face_uv(e, face, t.u0, t.v0, t.u1, t.v1, uv);
            push_box_face(bx, by, bz, face, lo, hi, uv, tint);
            model_faces_drawn += 1;
        }
    }
}

// Neighbour lookup that reaches into the column the caller provides, and
// reports air outside it (a chunk edge, or an unloaded neighbour). Meshing a
// chunk with its real neighbours is the caller's job; passing air is safe, it
// only costs a few faces at the seam.
fn neighbour(c: ChunkColumn&, x: i32, y: i32, z: i32) -> u32 {
    if x < 0 || x > 15 || z < 0 || z > 15 || y < -64 || y > 319 { return 0; }
    return chunk_block(c, x, y, z);
}

fn solid_at(c: ChunkColumn&, x: i32, y: i32, z: i32) -> bool {
    return is_solid(neighbour(c, x, y, z));
}

// Mesh every present section of a column into the shared arenas, tagging each
// triangle with its batch (0 opaque, 1 cutout, 2 translucent). The batches are
// emitted in order so the renderer can draw each with one call.
fn mesh_column(c: ChunkColumn&) {
    mesh_reset();
    // Opaque and cutout share the culling rules but not the draw state; a
    // block is in exactly one batch, so three passes over the section list
    // would cost more than one pass that records ranges. Emit per batch.
    for pass in 3 {
        // pass 0 opaque, 1 cutout (including plant crosses), 2 translucent
        let want = if pass == 0 { RC_OPAQUE } else if pass == 1 { RC_CUTOUT } else { RC_TRANSLUCENT };
        batch_starts[pass] = mesh_indices.len;
        for sy in -4..20 {
            mesh_section_class(c, sy as i32, want);
        }
        batch_counts[pass] = mesh_indices.len - batch_starts[pass];
    }
}

// The same as mesh_section but only for one render class, so the three batches
// can be emitted back to back.
fn mesh_section_class(c: ChunkColumn&, sy: i32, want: i64) {
    mesh_section_class_layers(c, sy, want, 0, 16);
}

// A section is 4096 blocks and one dense section measured 30-70 ms on the phone --
// far over the 50 ms the brief allows for an edit, because a unit cannot be
// interrupted. So the unit is a layer range inside the section: 16 layers of 256
// blocks, and the caller walks them. The blocks are still visited in the same
// order (x, then z, then y), so the mesh is byte-identical to meshing the whole
// section at once, which tools/run_tests.sh checks.
fn mesh_section_class_layers(c: ChunkColumn&, sy: i32, want: i64, ly_from: i32, ly_to: i32) {
    let idx = sy + 4;
    if idx < 0 || idx >= 24 { return; }
    if !c.sections[idx].present { return; }
    let base_y = sy * 16;
    let i_from = (ly_from as i64) * 256;
    let i_to = (ly_to as i64) * 256;
    if i_to <= i_from { return; }
    for k in (i_to - i_from) {
        let i = i_from + k;
        let x = (i % 16) as i32;
        let z = ((i / 16) % 16) as i32;
        let ly = (i / 256) as i32;
        let y = base_y + ly;
        let id = chunk_block(c, x, y, z);
        if id == 0 { continue; }
        let rc = render_class(id);
        // Plants are cutout for culling purposes but drawn as crosses; they
        // ride in the cutout batch so one draw call covers both.
        if want == RC_CUTOUT {
            if rc != RC_CUTOUT && rc != RC_CROSS { continue; }
        } else if rc != want {
            continue;
        }
        var tint: f32[3] = [1.0, 1.0, 1.0];
        let path = bs_path(bs_name(id));
        if mesh_store_on {
            // Every block whose blockstate names a model is drawn from that model, and
            // only from that model: a block whose faces were all culled away stays
            // invisible, it does not turn back into a cube. A block with no blockstate
            // at all falls through to the placeholder cube and is counted.
            if mesh_bs_of(id) < 0 {
                mesh_model_skipped += 1;
            } else {
                mesh_emit_model(c, x as i32, y as i32, z as i32, id);
                continue;
            }
        }
        if model_bound && id == model_block {
            // The single-bound demo path, kept for the placeholder world.
            push_model(c, x, y, z, tint);
            continue;
        }
        if ends_with(path, "_leaves") || rc == RC_CROSS { tint = [0.55, 0.75, 0.35]; }
        if rc == RC_TRANSLUCENT { tint = [0.3, 0.5, 1.0]; }
        if rc == RC_CROSS {
            push_cross(x as f32, y as f32, z as f32, tint, tex_uv(tex_face_slot(path, 2)));
            continue;
        }
        for face in 6 {
            let nx = x + (face_normal(face, 0) as i32);
            let ny = y + (face_normal(face, 1) as i32);
            let nz = z + (face_normal(face, 2) as i32);
            let nid = neighbour(c, nx, ny, nz);
            if is_solid(nid) { continue; }
            if rc == RC_TRANSLUCENT && nid == id { continue; }
            var ao: f32[4] = [1.0, 1.0, 1.0, 1.0];
            for corner in 4 {
                var ax: i32 = 0;
                var ay: i32 = 0;
                var az: i32 = 0;
                if face < 2 {
                    ax = if face_corner(face, corner, 0) > 0.5 { 1 } else { -1 };
                    az = if face_corner(face, corner, 2) > 0.5 { 1 } else { -1 };
                } else if face < 4 {
                    ax = if face_corner(face, corner, 0) > 0.5 { 1 } else { -1 };
                    ay = if face_corner(face, corner, 1) > 0.5 { 1 } else { -1 };
                } else {
                    az = if face_corner(face, corner, 2) > 0.5 { 1 } else { -1 };
                    ay = if face_corner(face, corner, 1) > 0.5 { 1 } else { -1 };
                }
                // Neighbours on the face's plane, one step out.
                var o1x: i32 = 0;
                var o1y: i32 = 0;
                var o1z: i32 = 0;
                var o2x: i32 = 0;
                var o2y: i32 = 0;
                var o2z: i32 = 0;
                if face < 2 { o1x = ax; o1z = 0; o2x = 0; o2z = az; }
                else if face < 4 { o1x = ax; o2y = ay; }
                else { o1y = ay; o2z = az; }
                let s1 = solid_at(c, nx + o1x, ny + o1y, nz + o1z);
                let s2 = solid_at(c, nx + o2x, ny + o2y, nz + o2z);
                let cc = solid_at(c, nx + o1x + o2x, ny + o1y + o2y, nz + o1z + o2z);
                ao[corner] = corner_ao(s1, s2, cc);
            }
            // The face samples its block's tile from the atlas. The rect is
            // inside the tile's gutter, so no bilinear sample can reach a
            // neighbour tile even at a glancing angle.
            let uv = tex_uv(tex_face_slot(path, face));
            push_quad(x as f32, y as f32, z as f32, face, uv[0], uv[1], uv[2], uv[3], tint, ao);
        }
    }
}
