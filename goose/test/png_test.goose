import std;
import os;
import core.mem;
import core.png;
import test.harness;

// Differential test: the PNGs were written by tools/gen_zip_png_fixtures.py
// with its own encoder, which also wrote the RGBA the decoder must produce.
fn run_png() {
    let dir = "goose/test/fixtures/png";
    var names: u8[>..] = [];
    names.append("rgba_f0\nrgba_f1\nrgba_f2\nrgba_f3\nrgba_f4\nrgba_f01234\nrgb\ngray\npalette\npalette4");
    var decoded = 0;
    each_split(names, '\n') {
        if it.len == 0 { }
        else {
            var p: u8[>..] = [];
            p.append(dir);
            p.push('/');
            p.append(it);
            var png_path: u8[>..] = [];
            png_path.append(p);
            png_path.append(".png");
            var want_path: u8[>..] = [];
            want_path.append(p);
            want_path.append(".rgba");
            var data: u8[>..] = [];
            var want: u8[>..] = [];
            if !read_file(png_path, data) || !read_file(want_path, want) {
                test_fail("cannot read png fixture");
                return;
            }
            var palette: u8[>..] = [];
            var rgba: u8[>..] = [];
            let info, ok, err = png_decode(data, palette, rgba);
            checks += 1;
            if !ok {
                failures += 1;
                print("FAIL: png ", it, ": ", err);
            } else if !eq_bytes(rgba, want) {
                failures += 1;
                print("FAIL: png ", it, ": ", info.width, "x", info.height, " ",
                      rgba.len, " bytes vs ", want.len, " expected");
            } else {
                decoded += 1;
            }
        }
    };
    // Negative test: broken PNGs must be refused, not decoded to garbage.
    var rejected = 0;
    each_split("bad_signature\nbad_crc\ntruncated\nempty", '\n') {
        if it.len == 0 { }
        else {
            var p: u8[>..] = [];
            p.append(dir);
            p.append("/bad_");
            p.append(it);
            p.append(".png");
            var data: u8[>..] = [];
            if read_file(p, data) {
                var palette: u8[>..] = [];
                var rgba: u8[>..] = [];
                let info, ok, err = png_decode(data, palette, rgba);
                checks += 1;
                if ok {
                    failures += 1;
                    print("FAIL: broken png accepted: ", it);
                } else {
                    rejected += 1;
                }
            }
        }
    };
    print("png: ", decoded, " images decoded to their expected RGBA, ", rejected, " broken refused");
    check(decoded == 10, "ten images decoded");
    check(rejected == 4, "four broken images refused");
    test_summary("png");
}
