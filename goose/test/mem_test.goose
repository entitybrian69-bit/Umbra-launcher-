import std;
import core.mem;
import test.harness;

fn run_mem() {
    // big-endian reads against hand-checked bytes
    let b: u8[8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0];
    check_u32(be_u16(b, 0), 0x1234, "be_u16");
    check_u32(be_u32(b, 0), 0x12345678, "be_u32");
    check(be_u64(b, 0) == 0x123456789ABCDEF0, "be_u64");
    check_i64(be_i16(b, 0), 0x1234, "be_i16");
    // little-endian
    let l: u8[4] = [0x78, 0x56, 0x34, 0x12];
    check_u32(le_u32(l, 0), 0x12345678, "le_u32");
    // float bit casts (0x3F800000 == 1.0f)
    let one: u8[4] = [0x3F, 0x80, 0x00, 0x00];
    check(be_f32(one, 0) == 1.0, "be_f32 1.0");
    // checksums: well-known vectors
    crc32_init();
    check_u32(crc32(""), 0x00000000, "crc32 empty");
    check_u32(crc32("123456789"), 0xCBF43926, "crc32 123456789");
    check_u32(crc32("The quick brown fox jumps over the lazy dog"), 0x414FA339, "crc32 fox");
    check_u32(adler32(""), 0x00000001, "adler32 empty");
    check_u32(adler32("Wikipedia"), 0x11E60398, "adler32 wikipedia");
    // LEB128 round trip
    var out: u8[>..] = [];
    put_leb(out, 0);
    put_leb(out, 127);
    put_leb(out, 128);
    put_leb(out, 255);
    put_leb(out, 4096);
    put_leb(out, 0xFFFFFFFF);
    var off = 0;
    let want: i64[6] = [0, 127, 128, 255, 4096, 0xFFFFFFFF];
    for i in 6 {
        let r = read_leb(out, off);
        check_i64(r.v as i64, want[i], "leb round trip");
        off += r.n;
    }
    check_i64(off, out.len, "leb consumed all");
    // writes are big-endian as documented
    var w: u8[>..] = [];
    put_be_u16(w, 0x1234);
    put_be_u32(w, 0x12345678);
    put_be_i64(w, -1);
    let want_w: u8[14] = [0x12, 0x34, 0x12, 0x34, 0x56, 0x78,
                          0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    check_bytes(w, want_w, "be writes");
    test_summary("mem");
}
