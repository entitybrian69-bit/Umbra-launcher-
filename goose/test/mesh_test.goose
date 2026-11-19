import std;
import os;
import core.mem;
import core.nbt;
import core.region;
import core.mesh;
import core.textures;
import core.models;
import core.demo;
import test.harness;

fn empty_column(c: ChunkColumn&) {
    // A column with every section present and air everywhere.
    for i in 24 {
        c.sections[i] = section_new();
        c.sections[i].present = true;
        c.sections[i].y = (i - 4) as i32;
    }
    c.section_lo = 0;
    c.section_hi = 23;
    c.x = 0;
    c.z = 0;
    c.present = true;
}

// A vertex samples a tile when both of its UV components are that tile's corners.
fn uv_in_rect(u: f32, v: f32, rect: f32[4]) -> bool {
    let u_ok = u == rect[0] || u == rect[2];
    let v_ok = v == rect[1] || v == rect[3];
    return u_ok && v_ok;
}

fn run_mesh() {
    bs_reset();
    let stone = bs_intern("minecraft:stone", "");
    let water = bs_intern("minecraft:water", "level=0");
    let grass = bs_intern("minecraft:grass_block", "snowy=false");
    let plant = bs_intern("minecraft:short_grass", "half=bottom");
    let leaves = bs_intern("minecraft:oak_leaves", "distance=7");
    let glass = bs_intern("minecraft:glass", "");

    // Render classes drive everything downstream; check them by name.
    check_i64(render_class(0), RC_AIR, "air class");
    check_i64(render_class(stone), RC_OPAQUE, "stone is opaque");
    check_i64(render_class(water), RC_TRANSLUCENT, "water is translucent");
    check_i64(render_class(glass), RC_TRANSLUCENT, "glass is translucent");
    check_i64(render_class(leaves), RC_CUTOUT, "leaves are cutout");
    check_i64(render_class(plant), RC_CROSS, "short_grass is a cross");

    // One stone block in open air: six faces, 24 vertices, 36 indices.
    var c = column_new();
    empty_column(c);
    chunk_set_block(c, 5, 5, 5, stone);
    mesh_column(c);
    check_i64(mesh_verts.len as i64, 24, "one block is 24 vertices");
    check_i64(mesh_indices.len as i64, 36, "one block is 36 indices");
    check_i64(batch_counts[0], 36, "all six faces are in the opaque batch");
    check_i64(batch_counts[1] + batch_counts[2], 0, "nothing in the other batches");
    var minx: f32 = 99.0;
    var maxx: f32 = -99.0;
    var miny: f32 = 99.0;
    var maxy: f32 = -99.0;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.x < minx { minx = v.x; }
        if v.x > maxx { maxx = v.x; }
        if v.y < miny { miny = v.y; }
        if v.y > maxy { maxy = v.y; }
    }
    check_f64(minx as f64, 5.0, "cube min x");
    check_f64(maxx as f64, 6.0, "cube max x");
    check_f64(miny as f64, 5.0, "cube min y");
    check_f64(maxy as f64, 6.0, "cube max y");
    var idx_ok = true;
    for i in mesh_indices.len {
        if mesh_indices[i] as i64 >= mesh_verts.len { idx_ok = false; }
    }
    check(idx_ok, "all indices address real vertices");
    // Normals: exactly four vertices per face direction.
    var dirs: i64[6] = [0, 0, 0, 0, 0, 0];
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.nx > 0.5 { dirs[0] += 1; }
        if v.nx < -0.5 { dirs[1] += 1; }
        if v.ny > 0.5 { dirs[2] += 1; }
        if v.ny < -0.5 { dirs[3] += 1; }
        if v.nz > 0.5 { dirs[4] += 1; }
        if v.nz < -0.5 { dirs[5] += 1; }
    }
    for i in 6 { check_i64(dirs[i], 4, "four vertices per face direction"); }
    // Face shading: the top face is brighter than the bottom.
    var top_shade: f32 = 0.0;
    var bottom_shade: f32 = 0.0;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.ny > 0.5 { top_shade = v.r; }
        if v.ny < -0.5 { bottom_shade = v.r; }
    }
    check(top_shade > bottom_shade, "top faces are brighter than bottom faces");

    // --- textures: every face samples its block's tile -----------------------
    tex_build();
    var all_in_atlas = true;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.u < 0.0 || v.u > 1.0 || v.v < 0.0 || v.v > 1.0 { all_in_atlas = false; }
    }
    check(all_in_atlas, "every UV is inside the atlas");
    // Stone's six faces all sample the same tile, so all eight distinct UV pairs
    // in a cube reduce to one rect.
    let stone_uv = tex_uv(TEX_STONE);
    var stone_ok = true;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.u != stone_uv[0] && v.u != stone_uv[2] { stone_ok = false; }
        if v.v != stone_uv[1] && v.v != stone_uv[3] { stone_ok = false; }
    }
    check(stone_ok, "a stone cube samples only the stone tile");

    // --- winding -------------------------------------------------------------
    // Back-face culling is on for the opaque pass, so every triangle has to be
    // counter-clockwise seen from outside the block. Checked here, in the mesher's
    // own output, and not by looking at a screenshot: a flipped quad is a hole,
    // and a hole on a phone reads as "the driver is broken".
    mesh_column(c);
    var flipped = 0;
    var k = 0;
    while k + 2 < mesh_indices.len {
        let a = mesh_verts[mesh_indices[k] as i64];
        let b = mesh_verts[mesh_indices[k + 1] as i64];
        let d = mesh_verts[mesh_indices[k + 2] as i64];
        let e1x = b.x - a.x;
        let e1y = b.y - a.y;
        let e1z = b.z - a.z;
        let e2x = d.x - a.x;
        let e2y = d.y - a.y;
        let e2z = d.z - a.z;
        // cross(e1, e2) must point along the face normal.
        let cx = e1y * e2z - e1z * e2y;
        let cy = e1z * e2x - e1x * e2z;
        let cz = e1x * e2y - e1y * e2x;
        let dot = cx * a.nx + cy * a.ny + cz * a.nz;
        if dot <= 0.0 { flipped += 1; }
        k += 3;
    }
    check_i64(flipped, 0, "every triangle faces outwards (CCW against its normal)");

    // A grass block uses three tiles at once: top, side and bottom. If the mesher
    // took one tile per block, all six faces would sample the same texels.
    var grass_col: u32 = bs_intern("minecraft:grass_block", "snowy=false");
    var c2 = column_new();
    empty_column(c2);
    chunk_set_block(c2, 3, 3, 3, grass_col);
    mesh_column(c2);
    let top_uv = tex_uv(TEX_GRASS_TOP);
    let side_uv = tex_uv(TEX_GRASS_SIDE);
    let dirt_uv = tex_uv(TEX_DIRT);
    var top_hits = 0;
    var side_hits = 0;
    var bottom_hits = 0;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.ny > 0.5 && uv_in_rect(v.u, v.v, top_uv) { top_hits += 1; }
        if v.ny < -0.5 && uv_in_rect(v.u, v.v, dirt_uv) { bottom_hits += 1; }
        if v.ny == 0.0 && uv_in_rect(v.u, v.v, side_uv) { side_hits += 1; }
    }
    check_i64(top_hits, 4, "the grass block's top samples the grass top tile");
    check_i64(bottom_hits, 4, "its bottom samples dirt");
    check_i64(side_hits, 16, "its four sides sample the grass side tile");

    // A plant is cutout geometry with its own tile, both quads.
    var c3 = column_new();
    empty_column(c3);
    chunk_set_block(c3, 7, 3, 7, plant);
    mesh_column(c3);
    let plant_uv = tex_uv(TEX_PLANT);
    var plant_hits = 0;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if uv_in_rect(v.u, v.v, plant_uv) { plant_hits += 1; }
    }
    check_i64(plant_hits, 8, "both quads of a cross sample the plant tile");

    // A block buried in stone has no visible faces.
    var buried = column_new();
    empty_column(buried);
    for dy in -1..2 {
        for dz in -1..2 {
            for dx in -1..2 {
                chunk_set_block(buried, (5 + dx) as i32, (5 + dy) as i32, (5 + dz) as i32, stone);
            }
        }
    }
    mesh_column(buried);
    check_i64(mesh_indices.len as i64, 54 * 6, "a 3x3x3 stone cube shows only its 54 outer faces");

    // Two stone blocks side by side: 10 faces, not 12.
    var pair = column_new();
    empty_column(pair);
    chunk_set_block(pair, 4, 5, 5, stone);
    chunk_set_block(pair, 5, 5, 5, stone);
    mesh_column(pair);
    check_i64(mesh_indices.len as i64, 10 * 6, "shared face is culled");

    // Water does not cull against itself, and lands in the translucent batch.
    var pond = column_new();
    empty_column(pond);
    for dz in 0..4 {
        for dx in 0..4 {
            chunk_set_block(pond, (4 + dx) as i32, 5, (4 + dz) as i32, water);
        }
    }
    mesh_column(pond);
    check_i64(batch_counts[2], 48 * 6, "a 4x4 water slab emits its 48 outer faces (top, bottom and a 16-face rim)");
    check_i64(batch_counts[0], 0, "no opaque geometry");

    // Plants are crosses: two quads each, in the cutout batch.
    var meadow = column_new();
    empty_column(meadow);
    chunk_set_block(meadow, 3, 5, 3, plant);
    mesh_column(meadow);
    check_i64(mesh_indices.len as i64, 12, "a cross is two quads");
    check_i64(batch_counts[1], 12, "crosses are cutout");

    // Grass is a cube in the opaque batch.
    var lawn = column_new();
    empty_column(lawn);
    chunk_set_block(lawn, 0, 0, 0, grass);
    mesh_column(lawn);
    check_i64(mesh_indices.len as i64, 36, "grass block is a cube");

    // Two stacked stone blocks: 10 faces, and the shared face is culled in Y.
    var tower = column_new();
    empty_column(tower);
    chunk_set_block(tower, 2, 5, 2, stone);
    chunk_set_block(tower, 2, 6, 2, stone);
    mesh_column(tower);
    check_i64(mesh_indices.len as i64, 10 * 6, "stacked blocks cull their shared face");

    // A real region column: mesh it, check invariants, and hash the result so
    // any change in the mesher shows up as a diff in the printed hash.
    var data: u8[>..] = [];
    if read_file("goose/test/fixtures/region/r.0.0.mca", data) {
        var payload: u8[>..] = [];
        let ok, err = region_chunk_nbt(data, 0, 0, payload);
        check(ok, "region chunk readable for meshing");
        var nerr: u8[>..] = [];
        let root = nbt_parse(payload, nerr);
        check(root >= 0, "chunk nbt parses for meshing");
        var col = column_new();
        column_from_nbt(root, col);
        mesh_column(col);
        check(mesh_indices.len > 0, "real chunk produced geometry");
        check_i64(mesh_verts.len as i64 % 4, 0, "vertices come in quads");
        check_i64(mesh_indices.len as i64 % 6, 0, "indices come in triangles");
        var in_range = true;
        for i in mesh_verts.len {
            let v = mesh_verts[i];
            if (v.x < 0.0 || v.x > 16.0) || (v.z < 0.0 || v.z > 16.0) { in_range = false; }
        }
        check(in_range, "vertices stay inside the column");
        var hash: u32 = 2166136261;
        for i in mesh_verts.len {
            let v = mesh_verts[i];
            hash = (hash ^ f32_hash(v.x)) * 16777619;
            hash = (hash ^ f32_hash(v.y)) * 16777619;
            hash = (hash ^ f32_hash(v.z)) * 16777619;
            hash = (hash ^ f32_hash(v.ao)) * 16777619;
        }
        print("mesh: real chunk -> ", mesh_verts.len, " vertices, ", mesh_indices.len,
              " indices, fnv1a ", u64_to_hex(hash as u64, 8));
        check(hash != 2166136261, "mesh hash covers real data");
        check(mesh_verts.len > 1000, "a 12-section terrain column has thousands of vertices");
    }
    // --- a model instead of a cube ------------------------------------------
    // The slab is half a block tall, so its geometry comes from the model's box and
    // not from the unit cube: if the model path were ignored, the top of the
    // geometry would sit at y+1 instead of y+0.5.
    mdl_reset();
    let slab_json = "{\"textures\":{\"all\":\"minecraft:block/oak_planks\"},\"elements\":[{\"from\":[0,0,0],\"to\":[16,8,16],\"faces\":{\"down\":{\"texture\":\"#all\",\"cullface\":\"down\"},\"up\":{\"texture\":\"#all\"},\"north\":{\"texture\":\"#all\"},\"south\":{\"texture\":\"#all\"},\"west\":{\"texture\":\"#all\"},\"east\":{\"texture\":\"#all\"}}}]}";
    check_i64(mdl_parse(slab_json), 1, "the slab model parses");
    var c4 = column_new();
    empty_column(c4);
    var slab = bs_intern("minecraft:oak_slab", "type=bottom");
    chunk_set_block(c4, 2, 10, 2, slab);
    mesh_bind_model(slab);
    mesh_column(c4);
    check_i64(mesh_verts.len as i64, 24, "a floating slab is six faces");
    var top_y: f32 = -99.0;
    var bottom_y: f32 = 99.0;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.y > top_y { top_y = v.y; }
        if v.y < bottom_y { bottom_y = v.y; }
    }
    check_f64(top_y as f64, 10.5, "the slab's top is half a block up");
    check_f64(bottom_y as f64, 10.0, "and its bottom is the block's bottom");

    // A slab with a solid block under it loses exactly its bottom face, because
    // the model asked for `cullface: down` and the face is on the surface.
    var c5 = column_new();
    empty_column(c5);
    chunk_set_block(c5, 2, 10, 2, slab);
    chunk_set_block(c5, 2, 9, 2, stone);
    mesh_column(c5);
    var slab_bottom = 0;
    var slab_top = 0;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if v.ny < -0.5 && v.y == 10.0 { slab_bottom += 1; }
        if v.ny > 0.5 && v.y == 10.5 { slab_top += 1; }
    }
    check_i64(slab_bottom, 0, "the slab's bottom face is culled by the stone beneath");
    check_i64(slab_top, 4, "and its top face is still drawn");

    // Model faces sample their texture's tile, through the name the model gave.
    let planks_uv = tex_uv(TEX_PLANKS);
    // On the column with no stone beneath: every vertex of the slab comes from the
    // model, so every one of them samples the tile the model named.
    mesh_column(c4);
    var model_uv_ok = true;
    for i in mesh_verts.len {
        let v = mesh_verts[i];
        if !uv_in_rect(v.u, v.v, planks_uv) { model_uv_ok = false; }
    }
    check(model_uv_ok, "the model's faces sample the planks tile");

    test_summary("mesh");
}

// --- the chunk border ---------------------------------------------------
//
// The bug these hold: `neighbour()` reported air for anything outside 0..15, on the
// theory that passing air "only costs a few faces at the seam". It costs the opposite.
// A cullface test that sees air keeps a face it should drop, so every seam in the demo
// world carried both of its faces, back to back, inside solid stone: 49 222 of 93 841
// quads sat behind solid blocks on both sides. On a save it is worse, because its seams
// are wherever its author's chunks happened to end.
//
// These build real columns in `demo` so the neighbour lookup has a world to read.

// One column of solid stone from y=-64 to y=99, at chunk (cx, cz). Not pushed into
// `demo`: the caller decides whether it is alone or has neighbours.
fn seam_column(cx: i32, cz: i32) -> ChunkColumn {
    var c = column_new();
    let stone = bs_intern("minecraft:stone", "");
    for i in 24 {
        c.sections[i] = section_new();
        c.sections[i].present = true;
        c.sections[i].y = (i - 4) as i32;
    }
    c.section_lo = 0;
    c.section_hi = 23;
    c.x = cx;
    c.z = cz;
    c.present = true;
    for y in -64..100 {
        for z in 16 {
            for x in 16 {
                chunk_set_block(c, x as i32, y as i32, z as i32, stone);
            }
        }
    }
    return c
}

// Quads whose four vertices all lie on the plane `axis == plane` and all share the
// normal `sign` along that axis. A quad on a chunk border is what a seam is.
fn quads_on_plane(axis: i64, sign: f64, plane: f64) -> i64 {
    var n: i64 = 0;
    var k: i64 = 0;
    while k + 5 < mesh_indices.len {
        var all_plane = true;
        var ok_normal = true;
        for c in 4 {
            let v = mesh_verts[mesh_indices[k + c] as i64];
            let p = if axis == 0 { v.x } else { v.z };
            let nn = if axis == 0 { v.nx } else { v.nz };
            if (p as f64) != plane { all_plane = false; }
            if (nn as f64) != sign { ok_normal = false; }
        }
        if all_plane && ok_normal { n += 1; }
        k += 6;
    }
    return n
}

fn run_mesh_borders() {
    // 1. A column with no world keeps its seam faces. That is the safe answer when the
    // neighbours are not loaded, it is the old behaviour, and other tests in this file
    // depend on it: 164 blocks tall by 16 deep on the east plane.
    demo = [];
    var lone = seam_column(0, 0);
    mesh_column(lone);
    check_i64(quads_on_plane(0, 1.0, 16.0), 164 * 16, "with no world the east seam is drawn");

    // 2. Two columns, both solid stone: every block on the shared plane is a full cube,
    // so no face may survive on the border, in either direction.
    demo = [];
    demo.push(seam_column(0, 0));
    demo.push(seam_column(1, 0));
    check_i64(demo.len, 2, "two columns in the test world");
    mesh_column(demo[0]);
    check_i64(quads_on_plane(0, 1.0, 16.0), 0, "no +x face on the border: the neighbour is solid");
    check_i64(quads_on_plane(0, -1.0, 16.0), 0, "no -x face on the border either");

    // 3. Every other plane is untouched by the border rule: the column's own west plane
    // still has its faces, and the far side of the pair is not the meshed column's.
    check_i64(quads_on_plane(0, -1.0, 0.0), 164 * 16, "the west plane is not the border and keeps its faces");

    // 4. Break a block on the border. The face it uncovers belongs to the neighbour's
    // block -- the one at local x=0 of chunk (1,0) -- so only the neighbour can draw it.
    // This is the hole you could look through, and it is what an edit that names only its
    // own column used to leave behind.
    // Both columns keep their own local coordinates here -- mesh_column emits x and z in
    // 0..16 and the caller offsets them into the world -- so the neighbour's face on the
    // border is the one on *its* west plane, x == 0, and the block that used to hide it is
    // the one broken in the column to its west.
    chunk_set_block(demo[0], 15, 40, 8, 0);
    mesh_column(demo[1]);
    check_i64(quads_on_plane(0, -1.0, 0.0), 1, "breaking the border block reveals the neighbour's face");

    test_summary("mesh_borders");
    demo = [];
}

// --- the model counters count the world, not the last column --------------------
//
// "blocks drawn from a model" is the number that answers item 3: is the world drawn
// from the jar's blockstates, or from fallback cubes? It was reset by mesh_reset(),
// which runs once per column, so on a nine-column world it reported the ninth column
// (33347 blocks) instead of the world (300826) -- a number that meant something other
// than its name, which is worse than no number at all.
fn run_mesh_model_counts() {
    // A world of two columns, each with a different number of the one block that has a
    // model bound to it: column 0 gets three slabs, column 1 gets one. The counts are in
    // blocks and faces *drawn from a model*, so they differ per column -- which is the
    // only way this test can tell a per-world counter from a per-column one.
    let slab = bs_intern("minecraft:oak_slab", "type=bottom");
    mesh_bind_model(slab);

    demo = [];
    demo.push(seam_column(0, 0));
    demo.push(seam_column(1, 0));
    // Clear the stone that fills them: the test wants only the slabs to be there.
    for c in demo.len {
        for y in -64..100 {
            for z in 16 {
                for x in 16 { chunk_set_block(demo[c], x as i32, y as i32, z as i32, 0); }
            }
        }
    }
    for k in 3 { chunk_set_block(demo[0], 2, 10, (2 + k) as i32, slab); }
    chunk_set_block(demo[1], 5, 10, 5, slab);

    mesh_world_reset();
    mesh_column(demo[0]);
    let blocks_after_first = mesh_model_block_count();
    check_i64(blocks_after_first, 3, "the first column drew three blocks from its model");

    // The regression: mesh_reset() runs once per column, so before the fix this was 1
    // (the second column alone) instead of 4 (the world). The number is asserted through
    // the accessor the phone's log line uses.
    mesh_column(demo[1]);
    check_i64(mesh_model_block_count(), 4,
              "the second column adds to the world's count instead of replacing it");
    check(mesh_model_face_count() > 0, "and the faces drawn from the model are counted");

    // The explicit reset is the caller's to make, and it clears the world's count.
    mesh_world_reset();
    check_i64(mesh_model_block_count(), 0, "mesh_world_reset clears the count");

    // A placeholder world with nothing bound draws nothing from a model, and says 0
    // rather than leaving the last world's number in place.
    mesh_reset();
    let plain = bs_intern("minecraft:stone", "");
    var c = column_new();
    empty_column(c);
    chunk_set_block(c, 1, 1, 1, plain);
    mesh_column(c);
    check_i64(mesh_model_block_count(), 0, "stone is drawn as a cube, not from a model");

    test_summary("mesh_model_counts");
    demo = [];
}
