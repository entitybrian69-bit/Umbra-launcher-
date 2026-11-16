// Umbra core: where the game's own files come from, and why a phone has to be
// able to answer that question at all.
//
// The app draws a world with the client jar's own textures and block models
// (D-042). On the CI emulator the jar is pushed to /data/local/tmp by the harness;
// on a phone there is no such path, so until this file existed the phone drew the
// twelve-tile placeholder atlas. The brief's answer is an in-app flow, and this is
// its policy half: which version is pinned, where its manifest is, what a download
// has to prove before it becomes the app's jar, and what the app says while it is
// happening.
//
// Everything that can be decided without a network is decided here, where the test
// suite reaches it: the URL shape, the pin's identity, the "is this the right
// file" rule, the wording of every state the screen shows. The platform layer only
// moves bytes (Java's HttpURLConnection for TLS, a content Uri copy for the picker)
// and hands them back to be checked.
//
// The jar is never committed, never shipped and never published: it lives in the
// app's private files directory and is deleted if the owner uninstalls the app.

import std;
import os;
import core.sha1;
import core.json;

// The pin, the same one tools/fetch_jar.sh uses (DECISIONS.md, D-023/D-010):
// release 26.3, 41 483 720 bytes, sha1 e877b6a0...7b87. The manifest is Mojang's
// own version_manifest_v2.json; the jar's URL and hash come out of the version JSON
// it names, so the app never carries a hard-coded jar URL that could rot.
let UM_MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
let UM_VERSION = "26.3";
let UM_CLIENT_BYTES: i64 = 41483720;
let UM_CLIENT_SHA1 = "e877b6a07acd633fb3bb475002175cec036e7b87";

// Where the jar lives once it has been verified, in the app's private directory.
let UM_JAR_NAME = "client.jar";

// The states the "get game files" screen can be in. A number, so the screen's
// wording and the log line are one thing and the test suite can walk all of them.
// The words themselves are two arenas rather than a struct with two of them: a
// Goose struct may hold only one growable field, and the headline and the detail
// line have different lives anyway (one is replaced by the next state, the other
// by the next progress tick).
var um_text: u8[>..] = [];     // the headline
var um_detail: u8[>..] = [];   // the second line

let UM_ST_IDLE: i64 = 0;
let UM_ST_DOWNLOADING: i64 = 1;
let UM_ST_VERIFYING: i64 = 2;
let UM_ST_READY: i64 = 3;
let UM_ST_FAILED: i64 = 4;
let UM_ST_IMPORTED: i64 = 5;

// --- the manifest --------------------------------------------------------
//
// version_manifest_v2.json lists every version with its id, type and the URL and
// sha1 of that version's own JSON. Find the pinned id and return where its JSON
// is and what it must hash to.
var um_json_url: u8[>..] = [];
var um_json_sha1: u8[>..] = [];
var um_lockfile: u8[>..] = [];
var um_lockbytes: i64 = 0;

fn um_manifest_lookup(text: const u8[:]) -> bool {
    um_json_url = [];
    um_json_sha1 = [];
    let root = json_parse(text);
    if root < 0 { return false; }
    let latest = json_get(root, "latest");
    let versions = json_get(root, "versions");
    if json_kind(versions) != J_ARR { return false; }
    var c = json_first(versions);
    while c >= 0 {
        if json_str(json_get(c, "id")).len == UM_VERSION.len &&
           eq_bytes(json_str(json_get(c, "id")), UM_VERSION) {
            um_json_url.append(json_str(json_get(c, "url")));
            um_json_sha1.append(json_str(json_get(c, "sha1")));
            um_lockfile = [];
            um_lockfile.append("id ");
            um_lockfile.append(UM_VERSION);
            um_lockfile.append(" type ");
            um_lockfile.append(json_str(json_get(c, "type")));
            um_lockfile.append(" released ");
            um_lockfile.append(json_str(json_get(c, "releaseTime")));
            if json_kind(latest) == J_OBJ {
                um_lockfile.append(" | latest release ");
                um_lockfile.append(json_str(json_get(latest, "release")));
            }
            um_lockbytes = json_str(json_get(c, "time")).len as i64;
            return um_json_url.len > 0 && um_json_sha1.len == 40;
        }
        c = json_next(c);
    }
    return false;
}

fn um_version_url() -> const u8[:] { return um_json_url[..] }
fn um_version_sha1() -> const u8[:] { return um_json_sha1[..] }
fn um_manifest_summary() -> const u8[:] { return um_lockfile[..] }
// Where the version JSON said the jar is, and what its bytes must hash to. Written
// by um_version_lookup from the version JSON the manifest named.
var um_jar_url: u8[>..] = [];
var um_jar_sha1: u8[>..] = [];
var um_jar_bytes: i64 = 0;
var um_jar_from_json = false;

fn um_version_lookup(text: const u8[:]) -> bool {
    um_jar_url = [];
    um_jar_sha1 = [];
    um_jar_bytes = 0;
    um_jar_from_json = false;
    let root = json_parse(text);
    if root < 0 { return false; }
    let downloads = json_get(root, "downloads");
    if json_kind(downloads) != J_OBJ { return false; }
    let client = json_get(downloads, "client");
    if json_kind(client) != J_OBJ { return false; }
    um_jar_url.append(json_str(json_get(client, "url")));
    um_jar_sha1.append(json_str(json_get(client, "sha1")));
    um_jar_bytes = json_int(json_get(client, "size"));
    um_jar_from_json = um_jar_url.len > 0 && um_jar_sha1.len == 40 && um_jar_bytes > 0;
    return um_jar_from_json;
}

fn um_client_url() -> const u8[:] { return um_jar_url[..] }
fn um_client_sha1() -> const u8[:] { return um_jar_sha1[..] }
fn um_client_size() -> i64 { return um_jar_bytes }
// The size the pin says, for the case where the version JSON was not fetched.
fn um_pinned_size() -> i64 { return UM_CLIENT_BYTES }

// --- what a downloaded file has to prove -------------------------------
//
// Three things, in the order that costs least: it is a jar (a zip, because the
// model store and the atlas read it as one), it is the size the pin names, and its
// bytes hash to the pin's sha1. A file that passes none of them is deleted rather
// than kept "in case": a wrong jar that stays on disk is a wrong atlas next start.
var um_check_why: u8[>..] = [];

fn um_check_reason() -> const u8[:] { return um_check_why[..] }

fn um_check_file(path: const u8[:], want_bytes: i64, want_sha1: const u8[:]) -> bool {
    um_check_why = [];
    var data: u8[>..] = [];
    if !read_file(path, data) {
        um_check_why.append("the downloaded file could not be read back");
        return false;
    }
    if data.len < 22 {
        format(um_check_why, "the file is only ", data.len, " bytes: not a jar at all");
        return false;
    }
    // A zip starts with a local header or, for an empty archive, the end record.
    let sig = le_u32(data[0..], 0);
    if sig != 0x04034B50 && sig != 0x06054B50 {
        format(um_check_why, "the file does not start with a zip header (0x", sig as i64, ")");
        return false;
    }
    if want_bytes > 0 && data.len != want_bytes {
        format(um_check_why, "the file is ", data.len, " bytes, the pin says ", want_bytes);
        return false;
    }
    sha1_reset();
    sha1_update(data[..]);
    sha1_finish();
    if !sha1_matches_hex(want_sha1) {
        var got: u8[>..] = [];
        sha1_hex(got);
        um_check_why = [];
        um_check_why.append("the sha1 is ");
        um_check_why.append(got[..]);
        um_check_why.append(", the pin says ");
        um_check_why.append(want_sha1);
        return false;
    }
    return true
}

// The digest of whatever was last checked, for the log line.
var um_check_sha1: u8[>..] = [];
fn um_checksum_text() -> const u8[:] { return um_check_sha1[..] }

fn um_remember_digest() {
    um_check_sha1 = [];
    sha1_hex(um_check_sha1);
}

// --- the screen's words -------------------------------------------------
//
// One function decides what the screen says in each state, so that the log, the
// HUD and the smoke test read the same sentence. `now` and `total` are bytes.
fn um_state_set(kind: i64, now: i64, total: i64, extra: const u8[:]) -> i64 {
    um_text = [];
    um_detail = [];
    if kind == UM_ST_IDLE {
        um_text.append("The world is drawn with Minecraft's own textures and models.");
        um_detail.append("Download them from Mojang (you need to own Java Edition), or import a jar you already have.");
    } else if kind == UM_ST_DOWNLOADING {
        let pct = if total > 0 { (now * 100 / total) as i64 } else { 0 };
        format(um_text, "Downloading the game's files... ", pct, "%");
        format(um_detail, now / 1048576, " of ", total / 1048576, " MB from Mojang");
    } else if kind == UM_ST_VERIFYING {
        um_text.append("Checking the download against Mojang's own checksum...");
        um_detail.append("Nothing is used until its sha1 matches the published one.");
    } else if kind == UM_ST_READY {
        um_text.append("Ready: the world is drawn with the game's own textures and models.");
        um_detail.append(extra);
    } else if kind == UM_ST_FAILED {
        um_text.append("That did not work.");
        um_detail.append(extra);
    } else if kind == UM_ST_IMPORTED {
        um_text.append("Imported: that jar is now what draws the world.");
        um_detail.append(extra);
    } else {
        um_text.append("(unknown state)");
    }
    return kind
}

fn um_state_text() -> const u8[:] { return um_text[..] }
fn um_state_detail() -> const u8[:] { return um_detail[..] }

// --- the import path ----------------------------------------------------
//
// A jar the owner already has: picked through ACTION_OPEN_DOCUMENT, copied into
// the app's private directory, then checked by the same rule as a download - a
// zip, the pinned size, the pinned sha1. A pre-modded jar or a different version
// therefore cannot silently become the world's textures, and the screen says
// which of the three failed.
var um_import_text: u8[>..] = [];

fn um_import_verdict(path: const u8[:], got_bytes: i64) -> i64 {
    um_import_text = [];
    if got_bytes <= 0 {
        um_import_text.append("no file was picked");
        return 0;
    }
    let ok = um_check_file(path, UM_CLIENT_BYTES, UM_CLIENT_SHA1);
    um_remember_digest();
    if ok {
        format(um_import_text, "that is the pinned jar: ", got_bytes, " bytes, sha1 matches");
        return 1;
    }
    um_import_text.append(um_check_reason());
    return 0;
}

fn um_import_message() -> const u8[:] { return um_import_text[..] }

// --- the file names -----------------------------------------------------

// <files>/client.jar, the name jar_try() in the platform layer already looks for.
fn um_jar_path(files_dir: const u8[:]) -> u8[>..] {
    var p: u8[>..] = [];
    p.append(files_dir);
    p.append("/");
    p.append(UM_JAR_NAME);
    return p
}

// <files>/client.jar.part: where a download or a copy lands first. The verified
// file is only given the real name after its sha1 matched, so a crash mid-download
// leaves the previous (good) jar in place.
fn um_part_path(files_dir: const u8[:]) -> u8[>..] {
    var p: u8[>..] = [];
    p.append(files_dir);
    p.append("/");
    p.append(UM_JAR_NAME);
    p.append(".part");
    return p
}

// Does a verified jar already exist? This is what the screen asks first, and what
// decides whether the app shows the flow or the world.
fn um_jar_present(files_dir: const u8[:]) -> bool {
    var p = um_jar_path(files_dir);
    return file_exists(p[..])
}
