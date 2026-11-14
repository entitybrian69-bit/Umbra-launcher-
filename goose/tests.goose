import std;
import test.mem_test;
import test.inflate_test;
import test.zip_test;
import test.png_test;
import test.nbt_test;

fn main() {
    print("umbra core tests");
    run_mem();
    run_inflate();
    run_zip();
    run_png();
    run_nbt();
    print("all modules passed");
}

// A C host needs at least one export; this reports the test program's name.
export fn umbra_test_suite() -> const u8[:] { return "umbra-core-tests" }
