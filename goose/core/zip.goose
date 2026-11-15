// Umbra core: zip archive reading (APPNOTE 6.3.x, the parts a jar uses).
// The client jar, resource packs and Umbmods are all zips. No heap: archives
// are described in a table of entries plus one arena of names, and extraction
// writes into a caller destination.

import std;
import core.mem;
import core.inflate;

struct ZipEntry {
    name: Sref,
    method: u16,      // 0 stored, 8 deflate
    crc: u32,
    comp_size: i64,
    size: i64,
    local_off: i64,
}

struct ZipArchive {
    label: Sref,      // what the caller called this archive
    first: i64,       // index into zip_entries
    count: i64,
}

var zip_entries: ZipEntry[>..] = [];
var zip_archives: ZipArchive[>..] = [];
var zip_names: u8[>..] = [];       // entry names, concatenated
var zip_labels: u8[>..] = [];

fn zip_reset() {
    zip_entries = [];
    zip_archives = [];
    zip_names = [];
    zip_labels = [];
}

fn zip_name_of(e: ZipEntry) -> u8[:] { return zip_names[e.name.off .. e.name.off + e.name.len] }

// Find the end-of-central-directory record, which is the last structure in
// the file and may be followed by a comment of up to 64 KiB.
fn find_eocd(data: const u8[:]) -> i64 {
    if data.len < 22 { return -1; }
    var lo = data.len - 22 - 65535;
    if lo < 0 { lo = 0; }
    var i = data.len - 22;
    while i >= lo {
        if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
            return i;
        }
        i -= 1;
    }
    return -1;
}

// Parse the central directory. The archive's bytes are not retained: pass the
// same buffer to zip_extract.
fn zip_open(label: u8[:], data: const u8[:]) -> bool, u8[>..] {
    var err: u8[>..] = [];
    let eocd = find_eocd(data);
    if eocd < 0 {
        format(err, "zip: no end-of-central-directory record (", data.len, " bytes read)");
        return false, err;
    }
    let count = le_u16(data, eocd + 10) as i64;
    let cd_size = le_u32(data, eocd + 12) as i64;
    let cd_off = le_u32(data, eocd + 16) as i64;
    if cd_off + cd_size > data.len {
        format(err, "zip: central directory at ", cd_off, "+", cd_size, " is past the end of a ",
               data.len, "-byte file");
        return false, err;
    }
    let archive_index = zip_archives.len;
    let first = zip_entries.len;
    var p = cd_off;
    var n = 0;
    while n < count {
        if p + 46 > data.len { format(err, "zip: truncated central directory at ", p); return false, err; }
        if le_u32(data, p) != 0x02014B50 {
            format(err, "zip: bad central directory signature at ", p);
            return false, err;
        }
        let method = le_u16(data, p + 10);
        let crc = le_u32(data, p + 16);
        var csize = le_u32(data, p + 20) as i64;
        var usize = le_u32(data, p + 24) as i64;
        let name_len = le_u16(data, p + 28) as i64;
        let extra_len = le_u16(data, p + 30) as i64;
        let comment_len = le_u16(data, p + 32) as i64;
        let local = le_u32(data, p + 42) as i64;
        if p + 46 + name_len > data.len {
            format(err, "zip: entry name past end at ", p);
            return false, err;
        }
        let name_off = zip_names.len;
        for i in name_len { zip_names.push(data[p + 46 + i]); }
        // Zip64 sizes live in the extra field when the 32-bit fields saturate.
        if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF {
            var q = p + 46 + name_len;
            let end_extra = q + extra_len;
            while q + 4 <= end_extra {
                let id = le_u16(data, q);
                let sz = le_u16(data, q + 2) as i64;
                if id == 0x0001 {
                    var r = q + 4;
                    if usize == 0xFFFFFFFF && r + 8 <= end_extra {
                        usize = be_u64(data, r) as i64;
                        r += 8;
                    }
                    if csize == 0xFFFFFFFF && r + 8 <= end_extra {
                        csize = be_u64(data, r) as i64;
                        r += 8;
                    }
                }
                q += 4 + sz;
            }
        }
        zip_entries.push(ZipEntry {
            name: Sref { off: name_off, len: name_len },
            method: method, crc: crc, comp_size: csize, size: usize, local_off: local,
        });
        p += 46 + name_len + extra_len + comment_len;
        n += 1;
    }
    let label_off = zip_labels.len;
    zip_labels.append(label);
    zip_archives.push(ZipArchive {
        label: Sref { off: label_off, len: label.len },
        first: first, count: zip_entries.len - first,
    });
    return true, err;
}

fn zip_find(archive: i64, name: u8[:]) -> i64 {
    let a = zip_archives[archive];
    for i in a.count {
        let e = zip_entries[a.first + i];
        let en = zip_name_of(e);
        if en.len == name.len && eq_bytes(en, name) { return a.first + i; }
    }
    return -1;
}

fn zip_has(archive: i64, name: u8[:]) -> bool { return zip_find(archive, name) >= 0; }

// Extract entry `index` into `out` (appending), verifying the CRC-32 and the
// uncompressed length. A corrupt entry leaves nothing appended.
fn zip_extract(data: const u8[:], index: i64, out: u8[>..]&) -> bool, u8[>..] {
    var err: u8[>..] = [];
    let e = zip_entries[index];
    let lo = e.local_off;
    if lo + 30 > data.len {
        format(err, "zip: local header past end for ", zip_name_of(e));
        return false, err;
    }
    if le_u32(data, lo) != 0x04034B50 {
        format(err, "zip: bad local header signature for ", zip_name_of(e));
        return false, err;
    }
    let name_len = le_u16(data, lo + 26) as i64;
    let extra_len = le_u16(data, lo + 28) as i64;
    let start = lo + 30 + name_len + extra_len;
    if start + e.comp_size > data.len {
        format(err, "zip: data past end for ", zip_name_of(e));
        return false, err;
    }
    let start_out = out.len;
    if e.method == 0 {
        for i in e.comp_size { out.push(data[start + i]); }
    } else if e.method == 8 {
        let ok, derr = inflate_raw(data[start .. start + e.comp_size], out);
        if !ok { return false, derr; }
    } else {
        format(err, "zip: unsupported compression method ", e.method, " for ", zip_name_of(e));
        return false, err;
    }
    let got_len = out.len - start_out;
    if got_len != e.size {
        format(err, "zip: ", zip_name_of(e), " is ", got_len, " bytes, directory says ", e.size);
        return false, err;
    }
    let got_crc = crc32(out[start_out..out.len]);
    if got_crc != e.crc {
        format(err, "zip: crc mismatch for ", zip_name_of(e));
        return false, err;
    }
    return true, err;
}
