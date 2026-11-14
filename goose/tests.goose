import std;
import test.mem_test;
import test.inflate_test;

fn main() {
    print("umbra core tests");
    run_mem();
    run_inflate();
    print("all modules passed");
}

// A C host needs at least one export; this reports the test program's name.
export fn umbra_test_suite() -> const u8[:] { return "umbra-core-tests" }
