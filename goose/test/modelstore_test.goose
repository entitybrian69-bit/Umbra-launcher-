// Tests for the block model store: several models at once, the blockstate rules that
// choose between them, and the properties a real jar's blockstates use.

import std;
import core.mem;
import core.json;
import core.modelstore;
import test.harness;

// A model with one element and the given faces, as JSON text.
fn cube_json() -> const u8[:] {
    return "{\"textures\":{},\"elements\":[{\"from\":[0,0,0],\"to\":[16,16,16],\"faces\":{\"down\":{\"texture\":\"#all\"},\"up\":{\"texture\":\"#all\"},\"north\":{\"texture\":\"#all\",\"cullface\":\"north\"},\"south\":{\"texture\":\"#all\",\"cullface\":\"south\"},\"west\":{\"texture\":\"#all\",\"cullface\":\"west\"},\"east\":{\"texture\":\"#all\",\"cullface\":\"east\"}}}]}";
}

fn run_modelstore() {
    ms_reset();

    // --- more than one model at a time -------------------------------------
    ms_tex_reset();
    ms_tex_put("all", "block/stone");
    let cube = ms_build("minecraft:block/cube_all", json_parse(cube_json()));
    check_i64(cube, 0, "the first model parses");
    check_i64(ms_model_count(), 1, "and the store has one model");
    check_i64(ms_face_count(cube), 6, "with six faces");
    check(ms_model_full(cube), "a cube filling the block is a full cube");

    ms_tex_reset();
    ms_tex_put("all", "block/oak_planks");
    let slab_json = "{\"elements\":[{\"from\":[0,0,0],\"to\":[16,8,16],\"faces\":{\"down\":{\"texture\":\"#all\",\"cullface\":\"down\"},\"up\":{\"texture\":\"#all\"},\"north\":{\"texture\":\"#all\"},\"south\":{\"texture\":\"#all\"},\"west\":{\"texture\":\"#all\"},\"east\":{\"texture\":\"#all\"}}}]}";
    let slab = ms_build("minecraft:block/oak_slab", json_parse(slab_json));
    check_i64(slab, 1, "a second model goes in beside the first, not over it");
    check_i64(ms_model_count(), 2, "the store now has two models");
    check(!ms_model_full(slab), "a slab is not a full cube");
    check_i64(ms_model_find("minecraft:block/cube_all"), 0, "models are found by name");
    check_i64(ms_model_find("minecraft:block/nope"), -1, "and a missing one is -1");
    check_i64(ms_path_count(), 2, "two texture paths were interned");
    check_bytes(ms_path(0), "minecraft:block/stone", "with the namespace made explicit");
    check_bytes(ms_path(1), "minecraft:block/oak_planks", "and the both paths kept");

    // The slab's faces carry their own texture, not the cube's.
    let f0 = ms_face_start(slab);
    check_i64(msf_tex[f0], 1, "the slab's first face points at the planks path");
    check_i64(msf_cull[f0], 0, "and its down face can be culled against a neighbour below");

    // --- a blockstate with variants ---------------------------------------
    let stairs_bs = json_parse("{\"variants\":{\"facing=east,half=bottom,shape=straight\":{\"model\":\"minecraft:block/cube_all\"},\"facing=west,half=bottom,shape=straight\":{\"model\":\"minecraft:block/oak_slab\",\"y\":90},\"facing=east,half=top,shape=straight\":{\"model\":\"minecraft:block/oak_slab\",\"x\":180}}}");
    let bs = ms_bs_build("minecraft:oak_stairs", stairs_bs);
    check_i64(bs, 0, "the blockstate parses");
    check_i64(mts_bs[bs].rule_count, 3, "with three variants");

    check_i64(ms_select(bs, "facing=east,half=bottom,shape=straight", 0), 1,
              "a state picks exactly one variant");
    let r = ms_sel_at(0);
    check_i64(ms_rule_model(r), 0, "and the model that variant names");
    check_i64(ms_rule_yrot(r), 0, "with no rotation");

    check_i64(ms_select(bs, "facing=west,half=bottom,shape=straight", 0), 1, "another state, one variant");
    let r2 = ms_sel_at(0);
    check_i64(ms_rule_yrot(r2), 90, "which carries its own y rotation");
    check_i64(ms_rule_model(r2), 1, "and its own model");

    check_i64(ms_select(bs, "facing=east,half=top,shape=straight", 0), 1, "the top half is a variant too");
    check_i64(ms_rule_xrot(ms_sel_at(0)), 180, "with an x rotation of 180");

    check_i64(ms_select(bs, "facing=north,half=bottom,shape=straight", 0), 0,
              "a state no variant names draws nothing");

    // --- multipart ---------------------------------------------------------
    let fence_bs = json_parse("{\"multipart\":[{\"apply\":{\"model\":\"minecraft:block/cube_all\"}},{\"when\":{\"east\":\"true\"},\"apply\":{\"model\":\"minecraft:block/oak_slab\"}},{\"when\":{\"north\":\"low|tall\"},\"apply\":{\"model\":\"minecraft:block/oak_slab\",\"y\":270}}]}");
    let fbs = ms_bs_build("minecraft:oak_fence", fence_bs);
    check_i64(fbs, 1, "the multipart blockstate parses");
    // The unconditional part always applies; the others only when their property says.
    check_i64(ms_select(fbs, "east=false,north=none", 0), 1, "with no arms, only the post is drawn");
    check_i64(ms_select(fbs, "east=true,north=none", 0), 2, "an east arm adds its part");
    check_i64(ms_select(fbs, "east=false,north=low", 0), 2, "a north arm adds its part");
    check_i64(ms_select(fbs, "east=false,north=tall", 0), 2, "and so does the taller one");
    check_i64(ms_select(fbs, "east=true,north=tall", 0), 3, "both arms together draw three parts");
    let arm = ms_sel_at(2);
    check_i64(ms_rule_yrot(arm), 270, "the arm keeps the rotation its part asked for");

    // --- weighted variants -------------------------------------------------
    let grass_bs = json_parse("{\"variants\":{\"\":[{\"model\":\"minecraft:block/cube_all\",\"weight\":9},{\"model\":\"minecraft:block/oak_slab\",\"weight\":1}]}}");
    let gbs = ms_bs_build("minecraft:grass_block", grass_bs);
    check_i64(gbs, 2, "the weighted blockstate parses");
    var seen_a = 0;
    var seen_b = 0;
    for h in 10 {
        let n = ms_select(gbs, "", h);
        check_i64(n, 1, "a weighted variant still draws exactly one model");
        if ms_rule_model(ms_sel_at(0)) == 0 { seen_a += 1; } else { seen_b += 1; }
    }
    check(seen_a > 0 && seen_b > 0, "and the weight decides which, by position");
    check(seen_a > seen_b, "the heavier variant wins more often");

    // --- a blockstate naming a model that does not exist -------------------
    let broken = json_parse("{\"variants\":{\"\":{\"model\":\"minecraft:block/does_not_exist\"}}}");
    let bbs = ms_bs_build("minecraft:broken", broken);
    check_i64(ms_select(bbs, "", 0), 0, "a missing model selects nothing");
    check_i64(ms_link_models(), 0, "and linking finds nothing to link");

    // --- a model built after its blockstate links up ----------------------
    ms_tex_reset();
    ms_tex_put("all", "block/dirt");
    let late = ms_build("minecraft:block/does_not_exist", json_parse(cube_json()));
    check(late >= 0, "a model can be built after the blockstate that names it");
    check_i64(ms_link_models(), 1, "and linking resolves the rule");
    check_i64(ms_select(bbs, "", 0), 1, "which now draws");

    test_summary("modelstore");
}
