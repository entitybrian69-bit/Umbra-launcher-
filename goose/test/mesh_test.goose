import std;
import os;
import core.mem;
import core.nbt;
import core.region;
import core.mesh;
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
    test_summary("mesh");
}
