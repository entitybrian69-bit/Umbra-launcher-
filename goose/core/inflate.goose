// Umbra core: DEFLATE (RFC 1951) and zlib (RFC 1950) decompression.
// Written from the public specifications. Zip entries, PNG image data and
// Anvil region chunks all arrive through here.
//
// No heap and no recursion: the whole decoder is one function whose nested
// functions share the bit reader and the output builder as free variables.

import std;
import core.mem;

// Bit reader: DEFLATE packs bits least-significant first within each byte.
struct BitReader {
    src: const u8[:],
    pos: i64,      // next byte
    bitbuf: u32,
    bitcnt: i64,
    bad: bool,
}

struct Huffman {
    count: i64[16],
    symbols: i64[288],
}

fn huff_init(h: Huffman&) {
    for i in 16 { h.count[i] = 0; }
    for i in 288 { h.symbols[i] = 0; }
}

fn need_bits(r: BitReader&, n: i64) -> bool {
    while r.bitcnt < n {
        if r.pos >= r.src.len {
            r.bad = true;
            return false;
        }
        r.bitbuf |= (r.src[r.pos] as u32) << r.bitcnt;
        r.pos += 1;
        r.bitcnt += 8;
    }
    return true;
}

fn bits(r: BitReader&, n: i64) -> u32 {
    if n == 0 { return 0; }
    if !need_bits(r, n) { return 0; }
    let v = r.bitbuf & ((1 << n) - 1);
    r.bitbuf = r.bitbuf >> n;
    r.bitcnt -= n;
    return v;
}

// Build a canonical Huffman table from code lengths, as RFC 1951 3.2.2
// describes: count the codes of each length, then fill symbols in the
// canonical order the standard requires.
fn huff_build(h: Huffman&, lengths: const u8[:], n: i64) -> bool {
    huff_init(h);
    for i in n { h.count[lengths[i]] += 1; }
    if h.count[0] == n { return true; }  // no codes at all: allowed, decodes nothing
    var left = 1;
    for len in 1..16 {
        left <<= 1;
        left -= h.count[len];
        if left < 0 { return false; }
    }
    var offs: i64[16] = [0; 16];
    for len in 1..15 { offs[len + 1] = offs[len] + h.count[len]; }
    for sym in 0..n {
        let l = lengths[sym];
        if l != 0 {
            h.symbols[offs[l]] = sym;
            offs[l] += 1;
        }
    }
    return true;
}

// Decode one symbol. Returns -1 on an invalid code.
fn huff_decode(r: BitReader&, h: Huffman&) -> i64 {
    var code = 0;
    var first = 0;
    var index = 0;
    for len in 1..16 {
        if !need_bits(r, 1) { return -1; }
        code |= (bits(r, 1) as i64);
        let count = h.count[len];
        if code - first < count {
            return h.symbols[index + (code - first)];
        }
        index += count;
        first = (first + count) << 1;
        code <<= 1;
    }
    return -1;
}

var length_base: i64[29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
var length_extra: i64[29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
var dist_base: i64[30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                          257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                          8193, 12289, 16385, 24577];
var dist_extra: i64[30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

// Inflate a raw DEFLATE stream into `out` (appending). On failure, returns
// false and the reason.
fn inflate_raw(src: const u8[:], out: u8[>..]&) -> bool, u8[>..] {
    var err: u8[>..] = [];
    var r = BitReader { src: src, pos: 0, bitbuf: 0, bitcnt: 0, bad: false };
    var lit = Huffman { count: [0; 16], symbols: [0; 288] };
    var dist = Huffman { count: [0; 16], symbols: [0; 288] };
    var ok = true;
    var done = false;
    var fixed_ready = false;

    fn build_fixed() {
        var lens: u8[288] = [0; 288];
        for i in 0..144 { lens[i] = 8; }
        for i in 144..256 { lens[i] = 9; }
        for i in 256..280 { lens[i] = 7; }
        for i in 280..288 { lens[i] = 8; }
        if !huff_build(lit, lens, 288) { ok = false; }
        var dl: u8[32] = [0; 32];
        for i in 32 { dl[i] = 5; }
        if !huff_build(dist, dl, 32) { ok = false; }
        fixed_ready = true;
    }

    // The symbol loop shared by fixed and dynamic blocks.
    fn symbols_loop(hlit: i64) {
        while ok {
            let sym = huff_decode(r, lit);
            if sym < 0 {
                ok = false;
                format(err, "deflate: invalid literal/length code at ", r.pos);
                return;
            }
            if sym < 256 {
                out.push(sym as u8);
            } else if sym == 256 {
                return;
            } else {
                let li = sym - 257;
                if li >= 29 {
                    ok = false;
                    format(err, "deflate: length symbol out of range");
                    return;
                }
                let len = length_base[li] + (bits(r, length_extra[li]) as i64);
                let dsym = huff_decode(r, dist);
                if dsym < 0 || dsym >= 29 {
                    ok = false;
                    format(err, "deflate: invalid distance code at ", r.pos);
                    return;
                }
                let d = dist_base[dsym] + (bits(r, dist_extra[dsym]) as i64);
                if d > out.len {
                    ok = false;
                    format(err, "deflate: distance ", d, " before start of output");
                    return;
                }
                // Overlapping copy is legal and is what makes run-length
                // sequences cheap; indexing from the moving end gives it.
                for i in len {
                    let b = out[out.len - d];
                    out.push(b);
                }
            }
            if r.bad {
                ok = false;
                format(err, "deflate: stream ended inside a block");
                return;
            }
        }
    }

    while !done && ok {
        let last = bits(r, 1);
        let btype = bits(r, 2);
        if r.bad { ok = false; format(err, "deflate: truncated header"); break; }
        if btype == 0 {
            // Stored block: discard to a byte boundary, then LEN/NLEN.
            r.bitbuf = 0;
            r.bitcnt = 0;
            if r.pos + 4 > src.len {
                ok = false;
                format(err, "deflate: truncated stored header at ", r.pos);
                break;
            }
            let len = le_u16(src, r.pos);
            let nlen = le_u16(src, r.pos + 2);
            if (len ^ 0xFFFF) != nlen {
                ok = false;
                format(err, "deflate: stored LEN/NLEN mismatch at ", r.pos);
                break;
            }
            r.pos += 4;
            if r.pos + len > src.len {
                ok = false;
                format(err, "deflate: stored block past end at ", r.pos);
                break;
            }
            for i in len { out.push(src[r.pos + i]); }
            r.pos += len;
        } else if btype == 1 {
            if !fixed_ready { build_fixed(); }
            symbols_loop(288);
        } else if btype == 2 {
            let hlit = (bits(r, 5) as i64) + 257;
            let hdist = (bits(r, 5) as i64) + 1;
            let hclen = (bits(r, 4) as i64) + 4;
            let order: i64[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
            var cl_lens: u8[19] = [0; 19];
            for i in hclen { cl_lens[order[i]] = bits(r, 3) as u8; }
            var cl = Huffman { count: [0; 16], symbols: [0; 288] };
            if r.bad || !huff_build(cl, cl_lens, 19) {
                ok = false;
                format(err, "deflate: bad code-length code");
                break;
            }
            var all: u8[320] = [0; 320];
            var idx = 0;
            let total = hlit + hdist;
            while idx < total {
                let sym = huff_decode(r, cl);
                if sym < 0 || r.bad {
                    ok = false;
                    format(err, "deflate: bad code length symbol");
                    break;
                }
                if sym < 16 {
                    all[idx] = sym as u8;
                    idx += 1;
                } else {
                    var rep = 0;
                    var val: u8 = 0;
                    if sym == 16 {
                        if idx == 0 {
                            ok = false;
                            format(err, "deflate: repeat with no previous length");
                            break;
                        }
                        val = all[idx - 1];
                        rep = 3 + (bits(r, 2) as i64);
                    } else if sym == 17 {
                        rep = 3 + (bits(r, 3) as i64);
                    } else {
                        rep = 11 + (bits(r, 7) as i64);
                    }
                    if idx + rep > total {
                        ok = false;
                        format(err, "deflate: code length repeat overruns");
                        break;
                    }
                    for i in rep {
                        all[idx] = val;
                        idx += 1;
                    }
                }
            }
            if !ok { break; }
            if !huff_build(lit, all[0..hlit], hlit) {
                ok = false;
                format(err, "deflate: bad literal/length code");
                break;
            }
            if !huff_build(dist, all[hlit..hlit + hdist], hdist) {
                ok = false;
                format(err, "deflate: bad distance code");
                break;
            }
            symbols_loop(hlit);
        } else {
            ok = false;
            format(err, "deflate: reserved block type 3");
            break;
        }
        if last == 1 { done = true; }
    }
    if !ok && err.len == 0 { format(err, "deflate: malformed stream"); }
    return ok, err;
}

// --- zlib wrapper -------------------------------------------------------

// zlib streams in Anvil regions and PNG images: a two byte header (a
// compression method and flags byte) and an Adler-32 of the plaintext.
fn inflate_zlib(src: const u8[:], out: u8[>..]&) -> bool, u8[>..] {
    var err: u8[>..] = [];
    if src.len < 6 {
        format(err, "zlib: too short (", src.len, " bytes)");
        return false, err;
    }
    let cmf = src[0];
    let flg = src[1];
    if (cmf & 0x0F) != 8 {
        format(err, "zlib: not deflate (CM=", cmf & 0x0F, ")");
        return false, err;
    }
    let hdr = (cmf as u32) * 256 + (flg as u32);
    if hdr % 31 != 0 {
        format(err, "zlib: bad header check 0x", u64_to_hex(hdr as u64, 4));
        return false, err;
    }
    if (flg & 0x20) != 0 {
        format(err, "zlib: preset dictionary unsupported");
        return false, err;
    }
    let start = out.len;
    let ok, derr = inflate_raw(src[2..src.len - 4], out);
    if !ok { return false, derr; }
    let want = be_u32(src, src.len - 4);
    let got = adler32(out[start..out.len]);
    if want != got {
        format(err, "zlib: adler32 mismatch: stream says 0x", u64_to_hex(want as u64, 8),
               ", data is 0x", u64_to_hex(got as u64, 8));
        return false, err;
    }
    return true, err;
}
