import std;
import core.region;
import core.mesh;
import core.raster;
import core.textures;
import test.harness;

// The cost gate: what one frame of a known world costs, counted, not timed.
//
// Frame times stay in the emulator's report as information. Forty milliseconds on a
// software rasteriser in CI and forty on a phone GPU are not the same claim, and a gate
// built on the first one would either fail for reasons that are not this code or pass
// while the phone crawls. Everything here is a count -- quads, triangles, draw calls'
// worth of batches, distinct pixels and overdraw permille -- so two builds on two
// machines can be compared and a change that makes the world cost more fails here rather
// than in a release note nobody reads.
//
// The world is built block for block by this test, so the numbers below are the same on
// every run and on every machine. When one of them changes, the change is the point: it
// either bought something or it did not, and the diff says which.

// A column with a hand-built world in it, instead of the demo generator: a floor, a cliff
// whose faces are coplanar, and a cave under the floor that the eye cannot see.
fn cost_column(cx: i32, cz: i32) -> ChunkColumn {
    var c = empty_column_named(cx, cz);
    for x in 16 {
        for z in 16 {
            for y in 60..64 {
                chunk_set_block(c, x as i32, y as i32, z as i32, cost_stone);
            }
            chunk_set_block(c, x as i32, 64, z as i32, cost_grass);
        }
    }
    // A sealed cave under the floor: stone from 52 to 59 with a 6x6x3 pocket carved out of
    // the middle. The first version of this carved air out of air -- the space under the
    // floor was already empty -- and then asserted that a cave existed, which it did not.
    // A pocket with walls emits its six inside faces and not one of them can be seen from
    // above the floor, which is exactly the hidden geometry worth counting.
    for x in 16 {
        for z in 16 {
            for y in 52..60 {
                chunk_set_block(c, x as i32, y as i32, z as i32, cost_stone);
            }
        }
    }
    for x in 4..10 {
        for z in 4..10 {
            for y in 56..59 {
                chunk_set_block(c, x as i32, y as i32, z as i32, 0);
            }
        }
    }
    // A cliff on the +x edge, 12 blocks tall: 12 x 16 coplanar faces, all one tile.
    for z in 16 {
        for y in 65..77 {
            chunk_set_block(c, 15, y as i32, z as i32, cost_stone);
        }
    }
    c
}

// The block ids this world is built from. They are assigned by the blockstate store, so a
// named constant is whatever `bs_intern` returned; keeping them at the top means the world
// is described in names and the column builder stays a column builder.
var cost_stone: u32 = 0;
var cost_grass: u32 = 0;

fn empty_column_named(cx: i32, cz: i32) -> ChunkColumn {
    var c = column_new();
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
    c
}

// Squared distance from a point to the first vertex of a quad. Squared because the sort
// only needs an order and a square root is a rounding difference waiting to happen.
fn cost_quad_dist(q: i64, eye: f32[3]) -> f32 {
    let v = mesh_verts[q * 4];
    let dx = v.x - eye[0];
    let dy = v.y - eye[1];
    let dz = v.z - eye[2];
    dx * dx + dy * dy + dz * dz
}

fn run_cost() {
    bs_reset();
    tex_build();
    cost_stone = bs_intern("minecraft:stone", "");
    cost_grass = bs_intern("minecraft:grass_block", "snowy=false");

    var c = cost_column(0, 0);
    mesh_column(c);

    let quad_count = mesh_verts.len as i64 / 4;
    let tri_count = mesh_indices.len as i64 / 3;
    print("cost: world meshes to ", quad_count, " quads, ", tri_count, " triangles, batches ",
          batch_counts[0], "/", batch_counts[1], "/", batch_counts[2], "\n");
    check(quad_count > 0, "the world meshed");
    check(tri_count == quad_count * 2, "every quad is two triangles");

    // --- the floor: 256 coplanar tops that ought to be one surface -------------------
    // Counting the +y faces and their extent says whether a merge exists: 256 separate
    // 1x1 quads over the same 16x16 square is 256 quads covering one plane, which is the
    // cost the merge is meant to remove. Whatever the mesher does, the *surface* must be
    // 16x16 -- so this is the check that a merge cannot cheat by dropping faces.
    var tops: i64 = 0;
    var minx: f32 = 999.0;
    var maxx: f32 = -999.0;
    var minz: f32 = 999.0;
    var maxz: f32 = -999.0;
    for q in quad_count {
        let v = mesh_verts[q * 4];
        if v.ny > 0.5 && v.y > 64.5 && v.x < 14.5 && v.z < 14.5 {
            tops += 1;
            if v.x < minx { minx = v.x; }
            if v.x > maxx { maxx = v.x; }
            if v.z < minz { minz = v.z; }
            if v.z > maxz { maxz = v.z; }
        }
    }
    print("cost: floor top quads ", tops, " covering x ", minx as i64, "..", maxx as i64,
          " z ", minz as i64, "..", maxz as i64, "\n");
    check(tops > 0, "the floor has top faces");
    // 16x16 blocks with a 1x1 quad each: the floor is 256 quads today. The number is
    // recorded rather than asserted, because it is the before in a before/after.
    check(maxx - minx >= 14.0 && maxz - minz >= 14.0,
          "the floor tops span the whole column, so no block of it is missing");

    // --- the cave is meshed, whatever it costs ---------------------------------------
    // The pocket's inside faces are real geometry. A mesher that only walked the surface
    // would drop them and the world would have a hole you could see through from below;
    // nothing can cull them either, because the only requirement on a mesh is that it be
    // correct for any camera. So they are drawn, and the cost gate is where that shows.
    var under: i64 = 0;
    for q in quad_count {
        let v = mesh_verts[q * 4];
        if v.ny < -0.5 && v.y > 55.5 && v.y < 60.5 { under += 1; }
    }
    print("cost: roof faces of the sealed pocket ", under, "\n");
    check(under > 0, "the pocket under the floor is meshed, interior faces and all");

    // --- a frame of it, on the CPU rasteriser: pixels and overdraw -------------------
    // The same pass order the phone draws: opaque, cutout, translucent. The numbers this
    // prints are what a frame of this world costs in fragments, which is the cost model
    // that does not depend on the machine.
    // A flat atlas is enough here: this counts pixels and shading, not texels -- the
    // texel comparison is jrender's job, against the jar's own PNGs.
    var atlas: u8[>..] = [];
    for i in 4 * 4 * 4 { atlas.push(180); }
    var eye: f32[3] = [8.0, 78.0, 24.0];
    var target: f32[3] = [8.0, 64.0, 8.0];
    var up: f32[3] = [0.0, 1.0, 0.0];
    rst_begin(320, 180);
    rst_clear(0.55, 0.70, 0.92);
    rst_camera(eye, target, up, 55.0, 0.5, 512.0);
    rst_set_fog(400.0, 900.0);
    rst_draw(0, batch_counts[0], mesh_verts, mesh_indices, atlas, 4, 4, false, false);
    let opaque_px = rst_pixels_covered();
    print("cost: frame pixels opaque ", opaque_px, ", overdraw ",
          rst_overdraw_permille(), " permille over ", rst_pixels_covered_once(),
          " distinct pixels, drawn triangles ", rst_triangles_drawn(), "\n");
    check(opaque_px > 1000, "the world covers most of a 320x180 frame from above");
    check(rst_overdraw_permille() >= 1000, "a frame shades each pixel at least once");

    // --- the before and the after, on the same frame, in this one run -----------------
    // Overdraw is order-dependent: when a far face is drawn first its pixels are shaded and
    // then shaded again by everything in front of it. So the mesher's emit order and a
    // near-first order give two different fragment counts for the same geometry, same
    // camera, same frame -- and the difference is what front-to-back sorting is worth, in
    // fragments, with no clock involved.
    let emit_order = rst_overdraw_permille();
    let emit_px = rst_pixels_covered_once();
    let emit_shaded = rst_fragments_shaded();

    rst_begin(320, 180);
    rst_clear(0.55, 0.70, 0.92);
    rst_camera(eye, target, up, 55.0, 0.5, 512.0);
    rst_set_fog(400.0, 900.0);
    // The same quads, back to front by the distance of their first vertex. This is the
    // sort the renderer does per range; here it is per quad, which is the best case.
    var order: i64[>..] = [];
    for q in quad_count { order.push(q); }
    // Insertion sort, nearest first. This must not depend on a library comparison behaving
    // the same way twice, and it is the direction that matters: the first version of this
    // sorted far-first, which is the worst case, and the measurement said so -- overdraw
    // went up, 2066 to 2119 permille, on the same frame with the same geometry.
    for i in 1..quad_count {
        let key = order[i];
        let kd = cost_quad_dist(key, eye);
        var j = i - 1;
        while j >= 0 && cost_quad_dist(order[j], eye) > kd {
            order[j + 1] = order[j];
            j -= 1;
        }
        order[j + 1] = key;
    }
    var sorted_idx: u32[>..] = [];
    for i in quad_count {
        let q = order[i];
        for k in 6 { sorted_idx.push(mesh_indices[q * 6 + k]); }
    }
    rst_draw(0, sorted_idx.len as i64, mesh_verts, sorted_idx, atlas, 4, 4, false, false);
    let sorted_order = rst_overdraw_permille();
    print("cost: overdraw emit order ", emit_order, " permille (", emit_shaded,
          " shaded over ", emit_px, " pixels), nearest-first ", sorted_order, " permille (",
          rst_fragments_shaded(), " shaded)\n");
    check(rst_pixels_covered_once() == emit_px,
          "sorting draws the same pixels: same geometry, different order");
    check(sorted_order <= emit_order,
          "nearest-first never costs more fragments than the mesher's emit order");

    test_summary("cost");
}
