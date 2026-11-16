import std;
import core.mem;
import core.sha1;
import test.harness;

// SHA-1 against the published test vectors (FIPS 180-2 appendix A / RFC 3174) and
// against Python's hashlib, so the digest the app checks a download with is not
// checked against itself.
fn run_sha1() {
    var hex: u8[>..] = [];

    hex = [];
    sha1_reset();
    sha1_update("");
    sha1_finish();
    sha1_hex(hex);
    check_bytes(hex[..], "da39a3ee5e6b4b0d3255bfef95601890afd80709", "sha1 of the empty input");

    hex = [];
    sha1_reset();
    sha1_update("abc");
    sha1_finish();
    sha1_hex(hex);
    check_bytes(hex[..], "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 of abc");

    // 56 bytes: the length padding has to spill into a second block.
    hex = [];
    sha1_reset();
    sha1_update("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    sha1_finish();
    sha1_hex(hex);
    check_bytes(hex[..], "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
                "sha1 of the 56-byte vector");

    // A million 'a', fed in uneven pieces: the answer must not depend on how the
    // bytes are cut up, or a download read in 64 KB chunks would get a different
    // digest than the same bytes read whole.
    var big: u8[>..] = [];
    for i in 1000 { big.push('a'); }
    sha1_reset();
    for i in 1000 { sha1_update(big[..]); }
    sha1_finish();
    hex = [];
    sha1_hex(hex);
    check_bytes(hex[..], "34aa973cd4c4daa4f61eeb2bdbad27316534016f", "sha1 of a million a's");

    // The same million bytes in one call, and in 7-byte pieces.
    var whole: u8[>..] = [];
    for i in 1000000 { whole.push('a'); }
    sha1_reset();
    sha1_update(whole[..]);
    sha1_finish();
    hex = [];
    sha1_hex(hex);
    check_bytes(hex[..], "34aa973cd4c4daa4f61eeb2bdbad27316534016f",
                "sha1 of the same bytes in one call");
    sha1_reset();
    var k: i64 = 0;
    while k < whole.len as i64 {
        let n = if whole.len as i64 - k < 7 { whole.len as i64 - k } else { 7 };
        sha1_update(whole[k .. k + n]);
        k += n;
    }
    sha1_finish();
    hex = [];
    sha1_hex(hex);
    check_bytes(hex[..], "34aa973cd4c4daa4f61eeb2bdbad27316534016f",
                "sha1 does not depend on how the input is chunked");

    // The match predicate: a real digest matches, a wrong one does not, and a
    // truncated or over-long expected string never matches.
    check(sha1_matches_hex("34aa973cd4c4daa4f61eeb2bdbad27316534016f"),
          "the digest matches its own hex");
    check(sha1_matches_hex("34AA973CD4C4DAA4F61EEB2BDBAD27316534016F"),
          "the match is case-insensitive, like the manifest's own hex");
    check(!sha1_matches_hex("34aa973cd4c4daa4f61eeb2bdbad273165340160"),
          "one wrong character is a mismatch");
    check(!sha1_matches_hex("34aa973cd4c4daa4f61eeb2bdbad27316534016"),
          "a truncated expected digest is a mismatch, not a prefix match");
    check(!sha1_matches_hex(""), "an empty expected digest is a mismatch");

    test_summary("sha1");
}
