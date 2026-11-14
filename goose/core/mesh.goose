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
    // -Y
    0.0, 0.0, 0.0,  0.0, 0.0, 1.0,  1.0, 0.0, 1.0,  1.0, 0.0, 0.0,
    // +Y
    0.0, 1.0, 0.0,  1.0, 1.0, 0.0,  1.0, 1.0, 1.0,  0.0, 1.0, 1.0,
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

fn push_cross(x0: f32, y0: f32, z0: f32, tint: f32[3]) {
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
                u: if c == 0 || c == 1 { 0.0 } else { 1.0 },
                v: if c == 0 || c == 1 { 1.0 } else { 0.0 },
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
    let idx = sy + 4;
    if idx < 0 || idx >= 24 { return; }
    if !c.sections[idx].present { return; }
    let base_y = sy * 16;
    for i in 4096 {
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
        if ends_with(path, "_leaves") || rc == RC_CROSS { tint = [0.55, 0.75, 0.35]; }
        if rc == RC_TRANSLUCENT { tint = [0.3, 0.5, 1.0]; }
        if rc == RC_CROSS {
            push_cross(x as f32, y as f32, z as f32, tint);
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
            push_quad(x as f32, y as f32, z as f32, face, 0.0, 0.0, 1.0, 1.0, tint, ao);
        }
    }
}
