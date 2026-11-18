import std;
import test.mem_test;
import test.sha1_test;
import test.inflate_test;
import test.zip_test;
import test.png_test;
import test.nbt_test;
import test.region_test;
import test.json_test;
import test.mesh_test;
import test.atlas_test;
import test.models_test;
import test.modelstore_test;
import test.raster_test;
import test.worldzip_test;

fn main() {
    print("umbra core tests");
    run_mem();
    run_sha1();
    run_inflate();
    run_zip();
    run_png();
    run_nbt();
    run_region();
    run_json();
    run_mesh();
    run_atlas();
    run_models();
    run_modelstore();
    run_raster();
    run_worldzip();
    print("all modules passed");
}

// A C host needs at least one export; this reports the test program's name.
export fn umbra_test_suite() -> const u8[:] { return "umbra-core-tests" }
