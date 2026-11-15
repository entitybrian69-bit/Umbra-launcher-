// Umbra core: PNG decoding to RGBA8 (W3C PNG spec, third edition).
// Textures, the atlas source and the screenshot regression compare all read
// PNG through here. No heap: rows are unfiltered into a caller buffer.

import std;
import core.mem;
import core.inflate;

struct PngInfo {
    width: i64,
    height: i64,
    bit_depth: i64,
    color_type: i64,   // 0 gray, 2 rgb, 3 palette, 4 gray+alpha, 6 rgba
    interlace: i64,
    has_trns: bool,
    trns_off: i64,     // into the caller's palette/trns arena
    trns_len: i64,
}

fn png_channels(color_type: i64) -> i64 {
    if color_type == 0 { return 1; }
    if color_type == 2 { return 3; }
    if color_type == 3 { return 1; }
    if color_type == 4 { return 2; }
    if color_type == 6 { return 4; }
    return 0;
}

fn paeth(a: i64, b: i64, c: i64) -> i64 {
    let p = a + b - c;
    let pa = abs(p - a);
    let pb = abs(p - b);
    let pc = abs(p - c);
    if pa <= pb && pa <= pc { return a; }
    if pb <= pc { return b; }
    return c;
}

// Undo the per-scanline filters in place. `raw` holds the filter byte plus
// the row bytes of every row, as the PNG stream does.
fn unfilter(raw: u8[>..]&, stride: i64, rows: i64, bpp: i64) {
    for y in rows {
        let row_start = y * (stride + 1);
        let filter = raw[row_start];
        let data_start = row_start + 1;
        if filter == 0 { continue; }
        var x = 0;
        while x < stride {
            let i = data_start + x;
            let left = if x >= bpp { raw[i - bpp] as i64 } else { 0 };
            let up = if y > 0 { raw[i - (stride + 1)] as i64 } else { 0 };
            let ul = if y > 0 && x >= bpp { raw[i - (stride + 1) - bpp] as i64 } else { 0 };
            var add: i64 = 0;
            if filter == 1 { add = left; }
            else if filter == 2 { add = up; }
            else if filter == 3 { add = (left + up) / 2; }
            else if filter == 4 { add = paeth(left, up, ul); }
            raw[i] = (raw[i] as i64 + add) as u8;
            x += 1;
        }
    }
}

// Decode a PNG into `out_rgba` (appending width*height*4 bytes) and describe
// it in `info`. Palette entries are appended to `palette` as RGBA.
fn png_decode(data: const u8[:], palette: u8[>..]&, out_rgba: u8[>..]&) -> PngInfo, bool, u8[>..] {
    var err: u8[>..] = [];
    var info = PngInfo { width: 0, height: 0, bit_depth: 0, color_type: 0, interlace: 0,
                         has_trns: false, trns_off: -1, trns_len: 0 };
    if data.len < 8 || data[0] != 137 || data[1] != 80 || data[2] != 78 || data[3] != 71 {
        format(err, "png: bad signature");
        return info, false, err;
    }
    var idat: u8[>..] = [];
    var pal: u8[>..] = [];
    var trns: u8[>..] = [];
    var have_ihdr = false;
    var p = 8;
    var stop = false;
    var ok = true;
    while p + 8 <= data.len && !stop {
        let len = be_u32(data, p) as i64;
        let ty = data[p + 4 .. p + 8];
        if p + 12 + len > data.len {
            format(err, "png: chunk past end at ", p);
            ok = false;
            stop = true;
        } else {
            let body = data[p + 8 .. p + 8 + len];
            let want_crc = be_u32(data, p + 8 + len);
            // CRC covers the type and the data, so run the table over both
            // without copying them together.
            var c: u32 = 0xFFFFFFFF;
            for b in ty { c = crc_table[(c ^ (b as u32)) & 0xFF] ^ (c >> 8); }
            for b in body { c = crc_table[(c ^ (b as u32)) & 0xFF] ^ (c >> 8); }
            let crc_all = c ^ 0xFFFFFFFF;
            if crc_all != want_crc {
                format(err, "png: crc mismatch in ", ty, " chunk at ", p,
                       " (chunk says 0x", u64_to_hex(want_crc as u64, 8),
                       ", bytes are 0x", u64_to_hex(crc_all as u64, 8), ")");
                ok = false;
                stop = true;
            }
            if ty[0] == 'I' && ty[1] == 'H' && ty[2] == 'D' && ty[3] == 'R' {
                if len < 13 {
                    format(err, "png: IHDR too short");
                    ok = false;
                    stop = true;
                } else {
                    info.width = be_u32(body, 0) as i64;
                    info.height = be_u32(body, 4) as i64;
                    info.bit_depth = body[8] as i64;
                    info.color_type = body[9] as i64;
                    info.interlace = body[12] as i64;
                    have_ihdr = true;
                }
            } else if ty[0] == 'P' && ty[1] == 'L' && ty[2] == 'T' && ty[3] == 'E' {
                for b in body { pal.push(b); }
            } else if ty[0] == 't' && ty[1] == 'R' && ty[2] == 'N' && ty[3] == 'S' {
                for b in body { trns.push(b); }
            } else if ty[0] == 'I' && ty[1] == 'D' && ty[2] == 'A' && ty[3] == 'T' {
                for b in body { idat.push(b); }
            } else if ty[0] == 'I' && ty[1] == 'E' && ty[2] == 'N' && ty[3] == 'D' {
                stop = true;
            }
            p += 12 + len;
        }
    }
    if !ok { return info, false, err; }
    if !have_ihdr {
        format(err, "png: no IHDR");
        return info, false, err;
    }
    if info.interlace != 0 {
        format(err, "png: Adam7 interlacing is not supported");
        return info, false, err;
    }
    if info.width <= 0 || info.height <= 0 {
        format(err, "png: zero-sized image");
        return info, false, err;
    }
    let ch = png_channels(info.color_type);
    if ch == 0 {
        format(err, "png: unknown colour type ", info.color_type);
        return info, false, err;
    }
    let bits_per_pixel = ch * info.bit_depth;
    let stride = (info.width * bits_per_pixel + 7) / 8;
    let bpp = if bits_per_pixel >= 8 { bits_per_pixel / 8 } else { 1 };
    var raw: u8[>..] = [];
    let zok, zerr = inflate_zlib(idat, raw);
    if !zok { return info, false, zerr; }
    if raw.len < (stride + 1) * info.height {
        format(err, "png: image data is ", raw.len, " bytes, need ", (stride + 1) * info.height);
        return info, false, err;
    }
    unfilter(raw, stride, info.height, bpp);
    // Palette output as RGBA, so the atlas can treat every texture alike.
    if info.color_type == 3 || trns.len > 0 {
        info.trns_off = palette.len;
        if info.color_type == 3 {
            var i = 0;
            var entries = pal.len / 3;
            while i < entries {
                palette.push(pal[i * 3]);
                palette.push(pal[i * 3 + 1]);
                palette.push(pal[i * 3 + 2]);
                // tRNS in a palette image gives alpha per index.
                if i < trns.len { palette.push(trns[i]); } else { palette.push(255); }
                i += 1;
            }
            info.trns_len = palette.len - info.trns_off;
            info.has_trns = trns.len > 0;
        }
    }
    // Emit RGBA rows.
    for y in info.height {
        let rs = y * (stride + 1) + 1;
        for x in info.width {
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            var a: u8 = 255;
            if info.color_type == 3 {
                var idx: i64 = 0;
                if info.bit_depth == 8 {
                    idx = raw[rs + x] as i64;
                } else {
                    let per_byte = 8 / info.bit_depth;
                    let byte = raw[rs + x / per_byte] as i64;
                    let shift = (per_byte - 1 - (x % per_byte)) * info.bit_depth;
                    idx = (byte >> shift) & ((1 << info.bit_depth) - 1);
                }
                let o = info.trns_off + idx * 4;
                r = palette[o];
                g = palette[o + 1];
                b = palette[o + 2];
                a = palette[o + 3];
            } else if info.color_type == 0 {
                var v: i64 = 0;
                if info.bit_depth == 8 {
                    v = raw[rs + x] as i64;
                } else if info.bit_depth == 16 {
                    v = raw[rs + x * 2] as i64;
                } else {
                    let per_byte = 8 / info.bit_depth;
                    let byte = raw[rs + x / per_byte] as i64;
                    let shift = (per_byte - 1 - (x % per_byte)) * info.bit_depth;
                    v = (byte >> shift) & ((1 << info.bit_depth) - 1);
                    // Stretch to 0..255 as the spec's sample scaling does.
                    v = v * 255 / ((1 << info.bit_depth) - 1);
                }
                r = v as u8;
                g = r;
                b = r;
                if trns.len >= 2 {
                    let t = be_u16(trns, 0) as i64;
                    if v == t { a = 0; }
                }
            } else if info.color_type == 4 {
                let step = info.bit_depth / 8;
                r = raw[rs + x * 2 * step];
                g = r;
                b = r;
                a = raw[rs + (x * 2 + 1) * step];
            } else if info.color_type == 2 {
                let step = info.bit_depth / 8;
                r = raw[rs + x * 3 * step];
                g = raw[rs + (x * 3 + 1) * step];
                b = raw[rs + (x * 3 + 2) * step];
                if trns.len >= 6 {
                    let tr = be_u16(trns, 0) as i64;
                    let tg = be_u16(trns, 2) as i64;
                    let tb = be_u16(trns, 4) as i64;
                    if r as i64 == tr && g as i64 == tg && b as i64 == tb { a = 0; }
                }
            } else {
                let step = info.bit_depth / 8;
                r = raw[rs + x * 4 * step];
                g = raw[rs + (x * 4 + 1) * step];
                b = raw[rs + (x * 4 + 2) * step];
                a = raw[rs + (x * 4 + 3) * step];
            }
            out_rgba.push(r);
            out_rgba.push(g);
            out_rgba.push(b);
            out_rgba.push(a);
        }
    }
    return info, true, err;
}
