// Umbra core: SHA-1 (FIPS 180-4), because that is what the game's download
// manifest publishes and therefore the only way to know that a file the app
// fetched is the file Mojang published.
//
// A jar is 41 MB and arrives over the network; a size check alone says nothing
// (the manifest quotes the size too, but a truncated transfer of the same length
// is not a thing, while a wrong file of the right length is). The digest is
// checked before the file is allowed to become the app's client.jar, so a
// half-written or substituted download can never be what the world is drawn
// with.
//
// No heap, like the rest of the core: the caller feeds bytes in as many pieces
// as it has them, and the 20-byte digest is written out at the end.

import std;
import core.mem;

var sha1_h: u32[5] = [0; 5];
var sha1_block: u8[64] = [0; 64];
var sha1_used: i64 = 0;      // bytes buffered in sha1_block
var sha1_len: u64 = 0;       // total bytes fed, for the length padding

// The digest as 20 bytes, big-endian, for comparison with a hex string.
var sha1_out: u8[20] = [0; 20];
var sha1_out_valid = false;

fn sha1_rotl(v: u32, n: i64) -> u32 {
    // A shift by 32 is undefined in C, and a byte count of 0 reaches here when a
    // caller resets between blocks: mask the shift.
    let k = n & 31;
    if k == 0 { return v; }
    return (v << k) | (v >> (32 - k));
}

fn sha1_reset() {
    sha1_h[0] = 0x67452301;
    sha1_h[1] = 0xEFCDAB89;
    sha1_h[2] = 0x98BADCFE;
    sha1_h[3] = 0x10325476;
    sha1_h[4] = 0xC3D2E1F0;
    sha1_used = 0;
    sha1_len = 0;
    sha1_out_valid = false;
    for i in 20 { sha1_out[i] = 0; }
}

fn sha1_compress(blk: const u8[:]) {
    var w: u32[80] = [0; 80];
    for i in 16 { w[i] = be_u32(blk, i * 4); }
    for i in 16..80 { w[i] = sha1_rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1); }
    var a = sha1_h[0];
    var b = sha1_h[1];
    var c = sha1_h[2];
    var d = sha1_h[3];
    var e = sha1_h[4];
    for i in 80 {
        var f: u32 = 0;
        var k: u32 = 0;
        if i < 20 {
            f = (b & c) | ((b ^ 0xFFFFFFFF) & d);
            k = 0x5A827999;
        } else if i < 40 {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if i < 60 {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }
        let temp = sha1_rotl(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = sha1_rotl(b, 30);
        b = a;
        a = temp;
    }
    sha1_h[0] += a;
    sha1_h[1] += b;
    sha1_h[2] += c;
    sha1_h[3] += d;
    sha1_h[4] += e;
}

// Feed one piece. Any length, including 0.
fn sha1_update(data: const u8[:]) {
    var i: i64 = 0;
    while i < data.len as i64 {
        sha1_block[sha1_used] = data[i];
        sha1_used += 1;
        i += 1;
        if sha1_used == 64 {
            sha1_compress(sha1_block[..]);
            sha1_used = 0;
        }
    }
    sha1_len += data.len as u64;
}

// Finish and write the 20-byte digest into sha1_out.
fn sha1_finish() {
    let bits = sha1_len * 8;
    // Padding: 0x80, then zeroes until 56 bytes into a block, then the length in
    // bits as a big-endian 64-bit number.
    var fill: u8[72] = [0; 72];
    fill[0] = 0x80;
    var pad_len: i64 = 1;
    while ((sha1_used + pad_len) % 64) != 56 { pad_len += 1; }
    sha1_update(fill[..pad_len]);
    var tail: u8[8] = [0; 8];
    var v = bits;
    for i in 8 {
        tail[7 - i] = (v & 0xFF) as u8;
        v = v >> 8;
    }
    // The tail is exactly the last 8 bytes of the last block, so it goes in
    // without another length count of its own.
    let keep = sha1_len;
    sha1_update(tail[..]);
    sha1_len = keep;
    for i in 5 {
        sha1_out[i * 4] = ((sha1_h[i] >> 24) & 0xFF) as u8;
        sha1_out[i * 4 + 1] = ((sha1_h[i] >> 16) & 0xFF) as u8;
        sha1_out[i * 4 + 2] = ((sha1_h[i] >> 8) & 0xFF) as u8;
        sha1_out[i * 4 + 3] = (sha1_h[i] & 0xFF) as u8;
    }
    sha1_out_valid = true;
}

// The digest of a whole buffer, for the tests and for small inputs.
fn sha1(data: const u8[:]) -> u8[20] {
    sha1_reset();
    sha1_update(data);
    sha1_finish();
    return sha1_out;
}

fn sha1_digest() -> const u8[:] { return sha1_out[..] }

// Lowercase hex of the last digest, for a log line and for comparing with the
// manifest's own string: 40 characters, no terminator.
fn sha1_hex(out: u8[>..]&) {
    const digits = "0123456789abcdef";
    for i in 20 {
        out.push(digits[sha1_out[i] >> 4] as u8);
        out.push(digits[sha1_out[i] & 0xF] as u8);
    }
}

// Does the last digest match a 40-character hex string? Case-insensitive, and
// false for anything that is not 40 characters: a truncated expected value must
// never read as a match.
fn sha1_matches_hex(want: const u8[:]) -> bool {
    if want.len as i64 != 40 { return false; }
    if !sha1_out_valid { return false; }
    const digits = "0123456789abcdef";
    for i in 20 {
        let hi = sha1_out[i] >> 4;
        let lo = sha1_out[i] & 0xF;
        if hex_lower(digits[hi]) != hex_lower(want[i * 2]) { return false; }
        if hex_lower(digits[lo]) != hex_lower(want[i * 2 + 1]) { return false; }
    }
    return true;
}

fn hex_lower(c: u8) -> u8 {
    if c >= 'A' && c <= 'F' { return c + 32; }
    return c;
}
