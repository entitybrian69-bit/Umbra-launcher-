// Tests for block model parsing: the shapes the jar actually uses, as JSON in the
// test, plus the UV maths the mesher depends on.

import std;
import core.mem;
import core.models;
import test.harness;

fn run_models() {
    let CUBE_ALL = "{\"parent\":\"block/cube_all\",\"textures\":{\"all\":\"block/stone\"}}";
    let SLAB = "{\"textures\":{\"bottom\":\"block/oak_planks\",\"top\":\"#bottom\",\"side\":\"block/oak_planks\"},\"elements\":[{\"from\":[0,0,0],\"to\":[16,8,16],\"faces\":{\"down\":{\"texture\":\"#bottom\",\"cullface\":\"down\"},\"up\":{\"texture\":\"#top\",\"uv\":[0,0,16,16]},\"north\":{\"texture\":\"#side\",\"cullface\":\"north\",\"tintindex\":0},\"south\":{\"texture\":\"#side\",\"uv\":[16,0,0,16],\"rotation\":90},\"west\":{\"texture\":\"#side\"},\"east\":{\"texture\":\"#side\"}}}]}";
    // --- a template with no elements ----------------------------------------
    mdl_reset();
    check_i64(mdl_parse(CUBE_ALL), 0, "a template model parses and has no elements");
    check(mdl_parent_name().len > 0, "and its parent is recorded");

    // --- a slab: geometry, textures, uv, cullface, tint, rotation -----------
    mdl_reset();
    let n = mdl_parse(SLAB);
    check_i64(n, 1, "the slab has one element");
    let s = mdl_stats();
    check_i64(s.faces, 6, "six faces");
    check_i64(s.with_cull, 2, "two faces declare a cullface");
    check_i64(s.with_tint, 1, "one face declares a tint index");
    check_i64(s.rotated, 1, "one face is rotated");
    // `up` names [0,0,16,16], which is the default, so it does not count as an
    // explicit rect; `south` names [16,0,0,16], which does.
    check_i64(s.with_uv, 1, "one face names a non-default uv rect");

    var lo: f32[3] = [0.0, 0.0, 0.0];
    var hi: f32[3] = [0.0, 0.0, 0.0];
    mdl_elem_box(0, lo, hi);
    check(hi[1] < 0.51 && hi[1] > 0.49, "the slab is half a block tall");

    // `#top` resolved through `#bottom` to block/oak_planks: both faces of the
    // slab that name it must land on the same tile.
    check_bytes(mdl_texture_name(1), "block/oak_planks", "up resolves to the same texture as bottom");

    // Culling only applies to a face that is on the block's surface and that names
    // that side as its cullface.
    check(mdl_face_cullable(0, 0), "the down face can be culled");
    check(!mdl_face_cullable(0, 1), "the up face is mid-block and cannot");
    check(mdl_face_cullable(0, 2), "the north face can be culled");
    check(!mdl_face_cullable(0, 5), "the east face names no cullface");

    // --- UV mapping into a tile --------------------------------------------
    // A tile occupying (0.25,0.50)-(0.375,0.625) of the atlas.
    var uv: f32[4] = [0.0, 0.0, 0.0, 0.0];
    mdl_face_uv(0, 1, 0.25, 0.50, 0.375, 0.625, uv);
    check_f64(uv[0] as f64, 0.25, "a full-tile uv starts at the tile's corner");
    check_f64(uv[3] as f64, 0.625, "and ends at its far corner");

    // `south` names [16,0,0,16] (mirrored) and a 90 degree rotation, so the
    // corners swap: the rect still covers the whole tile, in the other direction.
    mdl_face_uv(0, 3, 0.25, 0.50, 0.375, 0.625, uv);
    check_f64(uv[0] as f64, 0.25, "a mirrored rect with a 90 degree rotation starts at the tile's corner");
    check_f64(uv[2] as f64, 0.375, "and ends at its far corner");
    check_f64(uv[1] as f64, 0.50, "v is unchanged by a horizontal mirror");

    // Every emitted UV stays inside its own tile, for every face and every
    // rotation: this is the property that keeps bilinear filtering from reaching a
    // neighbour tile.
    var inside = true;
    for f in 6 {
        for r in 4 {
            mdl_rot[0 * 6 + f] = r;
            mdl_face_uv(0, f, 0.25, 0.50, 0.375, 0.625, uv);
            if uv[0] < 0.25 || uv[0] > 0.375 || uv[2] < 0.25 || uv[2] > 0.375 ||
               uv[1] < 0.50 || uv[1] > 0.625 || uv[3] < 0.50 || uv[3] > 0.625 {
                inside = false;
            }
        }
    }
    check(inside, "every uv stays inside its tile at every rotation");

    // --- a broken model is refused, with a reason ---------------------------
    mdl_reset();
    check_i64(mdl_parse("{\"elements\":[{\"to\":[16,16,16]}]}"), -1,
              "an element without from is refused");
    check(mdl_error_text().len > 0, "with a message");
    test_summary("models");
}
