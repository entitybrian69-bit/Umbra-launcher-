import std;
import os;
import core.mem;
import core.inflate;
import test.harness;

// Differential test: every fixture was produced by zlib (Python's zlib), so a
// pass means the Goose decoder reproduces an independent implementation's
// output byte for byte on that input.
fn run_inflate() {
    var listing: u8[>..] = [];
    let dir = "goose/test/fixtures/inflate";
    if !list_dir(dir, listing) {
        test_fail("cannot list fixture directory; run tools/gen_inflate_fixtures.py");
        test_summary("inflate");
        return;
    }
    var good = 0;
    var bad_rejected = 0;
    var bad_names: i64 = 0;
    each_split(listing, '\n') {
        if it.len == 0 { }
        else {
        var path: u8[>..] = [];
        path.append(dir);
        path.push('/');
        path.append(it);
        if ends_with(it, ".deflate") {
            var raw: u8[>..] = [];
            var want: u8[>..] = [];
            var want_path: u8[>..] = [];
            want_path.append(path[0..path.len - 8]);
            want_path.append(".plain");
            if !read_file(path, raw) || !read_file(want_path, want) {
                test_fail("cannot read deflate fixture");
                return;
            }
            var out: u8[>..] = [];
            let ok, err = inflate_raw(raw, out);
            checks += 1;
            if !ok {
                failures += 1;
                print("FAIL: inflate ", it, ": ", err);
            } else if !eq_bytes(out, want) {
                failures += 1;
                print("FAIL: inflate ", it, ": output differs (", out.len, " vs ", want.len, " bytes)");
            } else {
                good += 1;
            }
        } else if ends_with(it, ".zlib") {
            var raw: u8[>..] = [];
            if !read_file(path, raw) {
                test_fail("cannot read zlib fixture");
                return;
            }
            var out: u8[>..] = [];
            let ok, err = inflate_zlib(raw, out);
            if starts_with(it, "bad_") {
                // The gate's own negative test: a corrupt stream must be refused.
                checks += 1;
                if ok {
                    failures += 1;
                    print("FAIL: broken fixture accepted: ", it);
                } else {
                    bad_rejected += 1;
                    bad_names += 1;
                }
            } else {
                var want: u8[>..] = [];
                var want_path: u8[>..] = [];
                want_path.append(path[0..path.len - 5]);
                want_path.append(".zplain");
                if !read_file(want_path, want) {
                    test_fail("cannot read zplain fixture");
                    return;
                }
                checks += 1;
                if !ok {
                    failures += 1;
                    print("FAIL: inflate_zlib ", it, ": ", err);
                } else if !eq_bytes(out, want) {
                    failures += 1;
                    print("FAIL: inflate_zlib ", it, ": output differs");
                } else {
                    good += 1;
                }
            }
        }
        }
    };
    print("inflate: ", good, " streams matched zlib byte for byte, ",
          bad_rejected, " corrupt streams rejected");
    check(bad_rejected == 4, "all four corrupt fixtures rejected");
    check(good >= 70, "at least 70 good streams decoded");
    test_summary("inflate");
}
