import std;
import os;
import core.mem;
import core.zip;
import test.harness;

// Differential test: the archives were written by Python's zipfile, and each
// extracted entry is compared byte for byte with the file that went in.
fn run_zip() {
    zip_reset();
    let dir = "goose/test/fixtures/zip";
    let names = "assets/minecraft/textures/block/stone.png\nassets/minecraft/blockstates/stone.json\ndata/minecraft/recipe/stick.json\nempty.txt\nbig.bin";
    var archives = 0;
    var corrupt_rejected = 0;
    var entries_ok = 0;
    each_split("level0.zip\nlevel1.zip\nlevel6.zip\nlevel9.zip", '\n') {
        if it.len == 0 { }
        else {
            var path: u8[>..] = [];
            path.append(dir);
            path.push('/');
            path.append(it);
            var data: u8[>..] = [];
            if !read_file(path, data) {
                test_fail("cannot read zip fixture");
                return;
            }
            let a = zip_archives.len;
            let ok, err = zip_open(it, data);
            checks += 1;
            if !ok {
                failures += 1;
                print("FAIL: zip_open ", it, ": ", err);
            } else {
                archives += 1;
                let ea = zip_archives[a];
                check_i64(ea.count, 5, "entry count");
                each_split(names, '\n') {
                    if it.len == 0 { }
                    else {
                        let idx = zip_find(a, it);
                        checks += 1;
                        if idx < 0 {
                            failures += 1;
                            print("FAIL: ", it, " missing from archive ", ea.label.off);
                        } else {
                            var got: u8[>..] = [];
                            var want: u8[>..] = [];
                            var want_path: u8[>..] = [];
                            want_path.append(dir);
                            want_path.push('/');
                            var flat: u8[>..] = [];
                            for c in it { flat.push(if c == '/' { '_' } else { c }); }
                            want_path.append(flat);
                            want_path.append(".expected");
                            let ok2, err2 = zip_extract(data, idx, got);
                            if !ok2 {
                                failures += 1;
                                print("FAIL: extract ", it, ": ", err2);
                            } else if !read_file(want_path, want) {
                                failures += 1;
                                print("FAIL: cannot read ", want_path);
                            } else if !eq_bytes(got, want) {
                                failures += 1;
                                print("FAIL: ", it, " differs (", got.len, " vs ", want.len, " bytes)");
                            } else {
                                entries_ok += 1;
                            }
                        }
                    }
                };
            }
        }
    };
    // Negative test: a wrong CRC and a flipped payload byte must be refused.
    var bad: u8[>..] = [];
    if read_file("goose/test/fixtures/zip/bad_crc_level6.zip", bad) {
        let a2 = zip_archives.len;
        let ok, err = zip_open("bad_crc_level6.zip", bad);
        checks += 1;
        check(ok, "corrupt zip still parses its directory");
        let idx = zip_find(a2, "empty.txt");
        checks += 1;
        check(idx >= 0, "corrupt zip still lists entries");
        var out: u8[>..] = [];
        let xok, xerr = zip_extract(bad, idx, out);
        checks += 1;
        if xok {
            failures += 1;
            print("FAIL: corrupt entry was extracted without complaint");
        } else {
            corrupt_rejected += 1;
        }
    }
    var payload: u8[>..] = [];
    if read_file("goose/test/fixtures/zip/bad_payload_level6.zip", payload) {
        let a3 = zip_archives.len;
        let pok, perr = zip_open("bad_payload_level6.zip", payload);
        checks += 1;
        check(pok, "payload-corrupt zip still parses its directory");
        let idx = zip_find(a3, "assets/minecraft/textures/block/stone.png");
        checks += 1;
        check(idx >= 0, "payload-corrupt zip lists the damaged entry");
        var out2: u8[>..] = [];
        let xok2, xerr2 = zip_extract(payload, idx, out2);
        checks += 1;
        if xok2 {
            failures += 1;
            print("FAIL: flipped payload byte was extracted without complaint");
        } else {
            corrupt_rejected += 1;
        }
    }
    print("zip: ", corrupt_rejected, " corrupt archives rejected");
    print("zip: ", archives, " archives, ", entries_ok, " entries matched their originals");
    check(archives == 4, "four archives opened");
    check(entries_ok == 20, "twenty entries extracted");
    test_summary("zip");
}
