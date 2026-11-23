// Tests for the software rasterizer: a picture it draws has to be checkable, or a
// picture of a jar's world proves nothing.

import std;
import core.mem;
import core.mesh;
import core.raster;
import test.harness;

// A 4x4 atlas: tile 0 is red, tile 1 is blue, with a transparent texel in tile 1 so
// the alpha test has something to throw away.
fn make_atlas(out: u8[>..]&) {
    out = [];
    for y in 4 {
        for x in 4 {
            if x < 2 {
                out.push(200); out.push(40); out.push(40); out.push(255);
            } else if x == 2 && y == 2 {
                out.push(0); out.push(0); out.push(0); out.push(0);
            } else {
                out.push(40); out.push(40); out.push(200); out.push(255);
            }
        }
    }
}

fn quad_verts(atlas_u0: f32, atlas_u1: f32, z: f32, out: Vertex[>..]&) {
    out = [];
    // A 2x2 block in front of the camera, facing -Z (towards it).
    out.push(Vertex { x: -1.0, y: -1.0, z: z, nx: 0.0, ny: 0.0, nz: 1.0,
                      u: atlas_u0, v: 1.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    out.push(Vertex { x: -1.0, y: 1.0, z: z, nx: 0.0, ny: 0.0, nz: 1.0,
                      u: atlas_u0, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    out.push(Vertex { x: 1.0, y: 1.0, z: z, nx: 0.0, ny: 0.0, nz: 1.0,
                      u: atlas_u1, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    out.push(Vertex { x: 1.0, y: -1.0, z: z, nx: 0.0, ny: 0.0, nz: 1.0,
                      u: atlas_u1, v: 1.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
}

fn run_raster() {
    var atlas: u8[>..] = [];
    make_atlas(atlas);
    rst_begin(64, 64);
    rst_clear(0.0, 0.0, 0.0);
    rst_set_fog(1000.0, 2000.0);   // far enough away that nothing fogs
    var eye: f32[3] = [0.0, 0.0, 5.0];
    var target: f32[3] = [0.0, 0.0, 0.0];
    var up: f32[3] = [0.0, 1.0, 0.0];
    rst_camera(eye, target, up, 60.0, 0.1, 100.0);

    var verts: Vertex[>..] = [];
    quad_verts(0.0, 1.0, 0.0, verts);          // the whole atlas, red half on the left
    var idx: u32[>..] = [0, 1, 2, 0, 2, 3];
    rst_draw(0, 6, verts, idx, atlas[..], 4, 4, false, false);
    check(rst_triangles_drawn() == 2, "two triangles were drawn");
    check(rst_pixels_covered() > 0, "and they covered pixels");

    // The quad is red on the left half of the atlas and blue on the right, so a
    // pixel on each side of the screen must carry the matching colour: this is the
    // check that would catch a flipped u axis.
    let left = rst_color_at(24, 32);
    let right = rst_color_at(40, 32);
    check(left >= 0 && (((left >> 16) & 0xFF) > 150), "the left of the screen is red");
    check(right >= 0 && (((right >> 0) & 0xFF) > 150), "the right of the screen is blue");
    // The top of the atlas is v=0, so the top of the quad carries the top row.
    check(rst_color_at(32, 8) >= 0, "the quad reaches the top of the frame");

    // Depth: a nearer quad drawn second wins, and drawn first it still wins.
    rst_clear(0.0, 0.0, 0.0);
    var near: Vertex[>..] = [];
    quad_verts(0.0, 0.5, 1.0, near);   // z = +1 is nearer the camera at z = 5
    var far_q: Vertex[>..] = [];
    quad_verts(0.5, 1.0, -3.0, far_q);
    rst_draw(0, 6, far_q, idx, atlas[..], 4, 4, false, false);
    rst_draw(0, 6, near, idx, atlas[..], 4, 4, false, false);
    let c1 = rst_color_at(32, 32);
    check(((c1 >> 16) & 0xFF) > 150, "a nearer quad drawn second hides the far one");
    rst_clear(0.0, 0.0, 0.0);
    rst_draw(0, 6, near, idx, atlas[..], 4, 4, false, false);
    rst_draw(0, 6, far_q, idx, atlas[..], 4, 4, false, false);
    let c2 = rst_color_at(32, 32);
    check(((c2 >> 16) & 0xFF) > 150, "and a nearer quad drawn first still hides it");

    // Alpha test: the transparent texel does not paint, so the background survives.
    rst_clear(0.0, 0.0, 0.0);
    var blue: Vertex[>..] = [];
    quad_verts(0.5, 1.0, 0.0, blue);
    rst_draw(0, 6, blue, idx, atlas[..], 4, 4, false, true);
    check(rst_discarded() > 0, "the alpha test threw texels away");
    // The transparent texel sits at the middle-right of the atlas; somewhere in that
    // region the cleared background must still be there.
    var holes: i64 = 0;
    // The transparent texel is at atlas (2,2), which lands around x 32..38, y 32..37
    // of the quad on screen.
    for y in 31..38 {
        for x in 31..39 {
            if rst_color_at(x, y) == 0 { holes += 1; }
        }
    }
    check(holes > 0, "so the background shows through the hole");

    // Fog: the same quad drawn through heavy fog ends up at the sky colour.
    rst_clear(0.55, 0.55, 0.55);
    rst_set_fog(0.0, 1.0);
    var red: Vertex[>..] = [];
    quad_verts(0.0, 0.5, 0.0, red);
    rst_draw(0, 6, red, idx, atlas[..], 4, 4, false, false);
    let fogged = rst_color_at(32, 32);
    let fr = (fogged >> 16) & 0xFF;
    let fb = fogged & 0xFF;
    check(fr > 100 && fb > 100, "a fully fogged pixel is the sky colour, not the texture");

    // Fog has to be measured from the *eye*, in the world the geometry is in. The phone
    // shipped the other thing for a while: the vertex shader subtracted a second origin
    // (the mesh centre for the overview, the player for a walking body) and fogged by the
    // distance from it, so a body 3 blocks from a wall read as 30 and the whole frame came
    // out the sky colour with thousands of ranges drawn -- runs 44951752864 through
    // 44979840981, six "blank" screenshots and a wrong diagnosis each time.
    //
    // Both ends are pinned here, because a fog that is always clear passes the first check
    // alone and a fog that is always sky passes the second: a wall 3 blocks from an eye
    // that is nowhere near the origin must keep its texture, and one 300 blocks behind it
    // must be sky.
    var wall: Vertex[>..] = [];
    // Same quad, moved out to where a body would be standing: eye at (500, 70, 500).
    wall.push(Vertex { x: 499.0, y: 69.0, z: 497.0, nx: 0.0, ny: 0.0, nz: 1.0,
                       u: 0.0, v: 1.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    wall.push(Vertex { x: 499.0, y: 71.0, z: 497.0, nx: 0.0, ny: 0.0, nz: 1.0,
                       u: 0.0, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    wall.push(Vertex { x: 501.0, y: 71.0, z: 497.0, nx: 0.0, ny: 0.0, nz: 1.0,
                       u: 0.5, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    wall.push(Vertex { x: 501.0, y: 69.0, z: 497.0, nx: 0.0, ny: 0.0, nz: 1.0,
                       u: 0.5, v: 1.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    var eye2: f32[3] = [500.0, 70.0, 500.0];
    var target2: f32[3] = [500.0, 70.0, 497.0];
    var up2: f32[3] = [0.0, 1.0, 0.0];
    // `rst_clear` sets the fog's colour as well as the background, so this is the phone's
    // clear colour, and "fully fogged" and "nothing drawn" are then the same pixel -- which
    // is exactly why a blank gallery screenshot could not be told from a wrong one.
    rst_clear(0.55, 0.70, 0.92);
    rst_camera(eye2, target2, up2, 60.0, 0.05, 320.0);
    rst_set_fog(24.0, 96.0);   // what the phone uses while walking
    rst_draw(0, 6, wall, idx, atlas[..], 4, 4, false, false);
    let close = rst_color_at(32, 32);
    check(((close >> 16) & 0xFF) > 150, "a wall 3 blocks away keeps its texture, not the sky");

    // And the far end: the same wall pushed out past the fog's far plane, and still
    // inside the camera's, so this measures the fog and not the clip.
    var far_wall: Vertex[>..] = [];
    far_wall.push(Vertex { x: 499.0, y: 69.0, z: 350.0, nx: 0.0, ny: 0.0, nz: 1.0,
                           u: 0.0, v: 1.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    far_wall.push(Vertex { x: 499.0, y: 71.0, z: 350.0, nx: 0.0, ny: 0.0, nz: 1.0,
                           u: 0.0, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    far_wall.push(Vertex { x: 501.0, y: 71.0, z: 350.0, nx: 0.0, ny: 0.0, nz: 1.0,
                           u: 0.5, v: 0.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    far_wall.push(Vertex { x: 501.0, y: 69.0, z: 350.0, nx: 0.0, ny: 0.0, nz: 1.0,
                           u: 0.5, v: 1.0, r: 1.0, g: 1.0, b: 1.0, ao: 1.0 });
    rst_clear(0.55, 0.70, 0.92);
    rst_draw(0, 6, far_wall, idx, atlas[..], 4, 4, false, false);
    let distant = rst_color_at(32, 32);
    check(((distant >> 16) & 0xFF) > 100 && (distant & 0xFF) > 100,
          "and one 150 blocks away is the sky, so the fog still reaches");

    // Overdraw is a *count*, not a time, which is why it can be a gate on a machine whose
    // frame times say nothing about a phone. It has to count what it claims: fragments that
    // passed the depth test, i.e. were shaded.
    // rst_begin, not just rst_clear: the depth buffer has to go back to 1.0 or every one of
    // these quads is rejected against the leftovers of the tests above and nothing is
    // counted at all -- which is how this test first "failed".
    rst_begin(64, 64);
    rst_clear(0.0, 0.0, 0.0);
    rst_camera(eye, target, up, 60.0, 0.1, 100.0);
    rst_set_fog(1000.0, 2000.0);
    var behind: Vertex[>..] = [];
    quad_verts(0.0, 0.5, -3.0, behind);    // further from the eye at z = 5
    var infront: Vertex[>..] = [];
    quad_verts(0.5, 1.0, 1.0, infront);    // nearer
    rst_begin(64, 64);
    rst_clear(0.0, 0.0, 0.0);
    rst_draw(0, 6, behind, idx, atlas[..], 4, 4, false, false);
    let once = rst_overdraw_permille();
    rst_draw(0, 6, infront, idx, atlas[..], 4, 4, false, false);
    let twice = rst_overdraw_permille();
    // The nearer quad is drawn over the further one, so the pixels it covers are shaded a
    // second time and overdraw goes above one per pixel. That is real overdraw and shows.
    // A single draw is exactly 1000: every pixel it covers is shaded once. The ratio is
    // against *distinct* pixels -- dividing shading work by the write count would be
    // dividing a number by itself and would sit at 1000 no matter how much was drawn.
    check(once == 1000, "one quad over nothing is one shade per pixel");
    check(twice > once, "drawing over a pixel raises the overdraw count");
    check(rst_fragments_shaded() > rst_pixels_covered_once(),
          "and shaded fragments exceed the pixels, which is what overdraw means");
    // 784 distinct pixels, 980 writes: the nearer quad overwrote 196 of them. Two numbers
    // that differ is exactly why the ratio needs the distinct count.
    check(rst_pixels_covered_once() < rst_pixels_covered(),
          "an overwritten pixel is counted as covered once, not once per write");

    // And the other direction: a quad *behind* one already drawn must add no shading at
    // all, because every one of its fragments fails the depth test. A counter that rose
    // here would be counting triangles rather than work.
    rst_begin(64, 64);
    rst_clear(0.0, 0.0, 0.0);
    rst_draw(0, 6, infront, idx, atlas[..], 4, 4, false, false);
    let before_hidden = rst_fragments_shaded();
    rst_draw(0, 6, behind, idx, atlas[..], 4, 4, false, false);
    check(rst_fragments_shaded() == before_hidden,
          "a face hidden behind another adds no shading, so the count is work and not geometry");

    test_summary("raster");
}
