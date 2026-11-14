import std;
import core.mem;

var failures = 0;
var checks = 0;

fn fail(what: u8[:]) {
    failures += 1;
    print("FAIL: ", what);
}

fn ok(cond: bool, what: u8[:]) {
    checks += 1;
    if !cond { fail(what); }
}

fn eq_i64(got: i64, want: i64, what: u8[:]) {
    checks += 1;
    if got != want {
        failures += 1;
        print("FAIL: ", what, " got ", got, " want ", want);
    }
}

fn eq_u32(got: u32, want: u32, what: u8[:]) {
    checks += 1;
    if got != want {
        failures += 1;
        print("FAIL: ", what, " got ", got, " want ", want);
    }
}

fn eq_bytes(got: const u8[:], want: const u8[:], what: u8[:]) {
    checks += 1;
    if !eq_bytes(got, want) {
        failures += 1;
        print("FAIL: ", what, " bytes differ");
    }
}

fn summary(module: u8[:]) {
    if failures == 0 {
        print("PASS ", module, " (", checks, " checks)");
    } else {
        print("FAILED ", module, " (", failures, "/", checks, " checks failed)");
        exit(1);
    }
}
