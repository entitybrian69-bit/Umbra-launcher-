import std;
import core.mem;
import core.nbt;
import test.harness;

fn run_nbt() {
    let path = "goose/test/fixtures/nbt/level.dat";
    var data: u8[>..] = [];
    if !read_file(path, data) {
        test_fail("cannot read nbt fixture; run tools/gen_nbt_fixtures.py");
        test_summary("nbt");
        return;
    }
    var err: u8[>..] = [];
    let root = nbt_parse(data, err);
    checks += 1;
    if root < 0 {
        failures += 1;
        print("FAIL: nbt parse: ", err);
        test_summary("nbt");
        return;
    }
    let d = nbt_child(root, "Data");
    check(d >= 0, "Data compound found");
    check_i64(nbt_nodes[root].tag, 10, "root is a compound");
    check_i64(nbt_nodes[nbt_path(root, "Data/Version/Id")].ival, 3955, "Data/Version/Id");
    check_i64(nbt_string(root, "x").len, 0, "missing string is empty");
    let level_name = nbt_path(root, "Data/LevelName");
    check(eq_bytes(nbt_string(d, "LevelName"), "Umbra test world"), "LevelName");
    check_i64(nbt_int(d, "version", -1), 19133, "version");
    check_i64(nbt_int(d, "LastPlayed", 0), 1763200000123, "LastPlayed is a long");
    check_i64(nbt_int(d, "GameType", -1), 0, "GameType");
    check_i64(nbt_int(d, "Difficulty", -1), 2, "Difficulty");
    check_i64(nbt_int(d, "SpawnX", -999), 16, "SpawnX");
    check_i64(nbt_int(d, "SpawnY", -999), 72, "SpawnY");
    check_i64(nbt_int(d, "SpawnZ", -999), -32, "SpawnZ");
    check_i64(nbt_int(d, "Time", -1), 6000, "Time");
    check_i64(nbt_int(d, "DayTime", -1), 6001, "DayTime");
    let seed = nbt_path(root, "Data/WorldGenSettings/seed");
    check_i64(nbt_nodes[seed].ival, 4242424242, "WorldGenSettings/seed");
    let bio = nbt_path(root, "Data/WorldGenSettings/dimensions/minecraft:overworld/generator/biome_source/type");
    check_i64(bio, bio, "path with a colon in a name resolves");
    check(eq_bytes(nbt_bytes_at(bio), "minecraft:multi_noise"), "biome_source type value");
    check_f64(nbt_double(d, "BorderCenterX", 1.0), 0.0, "BorderCenterX");
    check_f64(nbt_double(d, "BorderSize", 0.0), 59999968.0, "BorderSize");
    check_f64(nbt_double(d, "TestFloat", 0.0), 1.5, "TestFloat");
    check_f64(nbt_double(d, "TestDouble", 0.0), -2.25, "TestDouble");
    check_i64(nbt_int(d, "TestShort", 0), -300, "TestShort");
    check_i64(nbt_int(d, "TestLong", 0), -9007199254740993, "TestLong 64-bit exact");
    // Arrays
    let ba = nbt_child(d, "TestBytes");
    check_i64(nbt_nodes[ba].count, 4, "TestBytes length");
    let bayt = nbt_nodes[ba].payload;
    check_i64(nbt_payload[bayt.off + 3] as i64, 250, "TestBytes[3]");
    let ia = nbt_child(d, "SpawnProbe");
    check_i64(be_i32(nbt_payload, nbt_nodes[ia].payload.off + 4), 20, "SpawnProbe[1]");
    let la = nbt_child(d, "HeightmapsProbe");
    check_i64(be_i64(nbt_payload, nbt_nodes[la].payload.off + 8), -2, "HeightmapsProbe[1]");
    // Lists
    let ti = nbt_child(d, "TestInts");
    check_i64(nbt_nodes[ti].elem, 3, "TestInts element tag");
    check_i64(nbt_nodes[ti].count, 3, "TestInts length");
    let first_int = nbt_nodes[ti].first;
    check_i64(nbt_nodes[first_int].ival, 7, "TestInts[0]");
    check_i64(nbt_nodes[nbt_nodes[first_int].next].ival, -8, "TestInts[1]");
    let brands = nbt_child(d, "ServerBrands");
    check_i64(nbt_nodes[brands].count, 1, "ServerBrands length");
    check(eq_bytes(nbt_bytes_at(nbt_nodes[brands].first), "vanilla"), "ServerBrands[0]");
    let empty = nbt_child(d, "EmptyCompound");
    check_i64(nbt_count(empty), 0, "EmptyCompound has no children");
    let emptyl = nbt_child(d, "EmptyList");
    check_i64(nbt_nodes[emptyl].count, 0, "EmptyList is empty");
    check_i64(nbt_count(d), 40, "Data has 40 children");

    // Round trip: writing the parsed document must reproduce the file's bytes.
    var out: u8[>..] = [];
    nbt_write(out);
    check_bytes(out, data, "nbt write reproduces the input byte for byte");

    // Negative tests.
    var rejected = 0;
    each_split("bad_root_tag\nbad_truncated\nbad_empty\nbad_unknown_tag", '\n') {
        if it.len == 0 { }
        else {
            var p: u8[>..] = [];
            p.append("goose/test/fixtures/nbt/");
            p.append(it);
            p.append(".dat");
            var b: u8[>..] = [];
            let readable = read_file(p, b);
            if !readable && b.len > 0 {
                failures += 1;
                print("FAIL: cannot read ", p);
            } else if !readable {
                // A zero-byte file: read_file appends nothing, and an empty
                // document is exactly what the reader must refuse.
                var e2: u8[>..] = [];
                let r2 = nbt_parse(b, e2);
                checks += 1;
                if r2 >= 0 {
                    failures += 1;
                    print("FAIL: broken nbt accepted: ", it);
                } else {
                    rejected += 1;
                }
            } else {
                var e2: u8[>..] = [];
                let r2 = nbt_parse(b, e2);
                checks += 1;
                if r2 >= 0 {
                    failures += 1;
                    print("FAIL: broken nbt accepted: ", it);
                } else {
                    rejected += 1;
                }
            }
        }
    }
    print("nbt: parsed and rewrote level.dat byte for byte, ", rejected, " broken files refused");
    check_i64(rejected, 4, "all four broken files refused");
    test_summary("nbt");
}
