import std;
import core.mem;

var failures = 0;
var checks = 0;

fn test_fail(what: const u8[:]) {
    failures += 1;
    print("FAIL: ", what);
}

fn check(cond: bool, what: const u8[:]) {
    checks += 1;
    if !cond { test_fail(what); }
}

fn check_i64(got: i64, want: i64, what: const u8[:]) {
    checks += 1;
    if got != want {
        failures += 1;
        print("FAIL: ", what, " got ", got, " want ", want);
    }
}

fn check_u32(got: u32, want: u32, what: const u8[:]) {
    checks += 1;
    if got != want {
        failures += 1;
        print("FAIL: ", what, " got ", got, " want ", want);
    }
}

fn check_bytes(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if !eq_bytes(got, want) {
        failures += 1;
        print("FAIL: ", what, " bytes differ");
    }
}

fn check_f64(got: f64, want: f64, what: const u8[:]) {
    checks += 1;
    if got != want {
        failures += 1;
        print("FAIL: ", what, " got ", got, " want ", want);
    }
}

fn test_summary(module: u8[:]) {
    if failures == 0 {
        print("PASS ", module, " (", checks, " checks)");
    } else {
        print("FAILED ", module, " (", failures, "/", checks, " checks failed)");
        exit(1);
    }
}
