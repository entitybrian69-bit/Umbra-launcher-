// The "get game files" flow's policy, checked without a network or a phone.
//
// The app's screen has to answer four questions that no device test can ask: does
// the pinned version appear in Mojang's own manifest, does the version JSON it
// names point at a jar with the identity the pin records, is that the rule a
// downloaded file is held to, and does a jar that is *not* the pinned one get
// refused with a reason instead of quietly becoming the world's textures.
//
//   umbra_gamefiles <manifest.json> <version.json> <good.jar|-> <bad.jar|->
//
// Exit 0 when every check passed, 1 when one did not. The manifest and the version
// JSON are real files fetched by tools/fetch_jar.sh in CI; the jars are the real
// client jar and a deliberately wrong one.
import std;
import os;
import core.mem;
import core.zip;
import core.sha1;
import core.json;
import core.gamefiles;

var gf_checks: i64 = 0;
var gf_failures: i64 = 0;

fn gf_check(ok: bool, what: const u8[:]) {
    gf_checks += 1;
    if !ok {
        gf_failures += 1;
        print("FAIL: ", what, "\n");
    }
}

fn gf_arg(i: i64) -> u8[>..] {
    var v: u8[>..] = [];
    if arg_count() > i { arg(i, v); }
    return v
}

fn main() {
    if arg_count() < 5 {
        print("usage: umbra_gamefiles <manifest.json> <version.json> <good.jar|-> <bad.jar|->\n");
        exit(2);
    }
    var manifest = gf_arg(1);
    var version = gf_arg(2);
    var good = gf_arg(3);
    var bad = gf_arg(4);

    // --- the manifest names the pinned version, and its JSON has an identity ---
    var mtext: u8[>..] = [];
    if !read_file(manifest[..], mtext) {
        print("FAIL: cannot read the manifest\n");
        exit(1);
    }
    let found = um_manifest_lookup(mtext[..]);
    gf_check(found, "the pinned version is in Mojang's manifest");
    if !found {
        print("FAIL: ", UM_VERSION, " is not in ", manifest[..], "\n");
        exit(1);
    }
    print("gamefiles: ", um_manifest_summary()[..], "\n");
    print("gamefiles: version json ", um_version_url()[..], "\n");
    print("gamefiles: version json sha1 ", um_version_sha1()[..], "\n");
    gf_check(um_version_url().len > 0, "the manifest gives a URL for the version JSON");
    gf_check(um_version_sha1().len == 40, "and a 40-character sha1 for it");

    // --- the version JSON names a client jar we can check a download against ---
    var vtext: u8[>..] = [];
    if !read_file(version[..], vtext) {
        print("FAIL: cannot read the version JSON\n");
        exit(1);
    }
    let vok = um_version_lookup(vtext[..]);
    gf_check(vok, "the version JSON describes a downloadable client jar");
    print("gamefiles: client jar ", um_client_url()[..], "\n");
    print("gamefiles: client jar ", um_client_size(), " bytes, sha1 ", um_client_sha1()[..], "\n");
    gf_check(um_client_size() == um_pinned_size(),
             "the size in the version JSON is the size the pin records");
    gf_check(eq_bytes(um_client_sha1(), UM_CLIENT_SHA1),
             "the sha1 in the version JSON is the sha1 the pin records");

    // --- a file that is the pinned jar passes the check ---
    var good_path = good;
    if good_path.len > 1 {
        let ok = um_check_file(good_path[..], um_client_size(), um_client_sha1());
        print("gamefiles: the client jar is ", if ok { "the pinned one" } else { "NOT the pinned one" }, "\n");
        gf_check(ok, "the real client jar passes the download check");
        if !ok { print("FAIL: reason: ", um_check_reason(), "\n"); }
        if ok {
            print("gamefiles: its sha1 is ", um_checksum_text()[..], "\n");
            gf_check(eq_bytes(um_checksum_text(), um_client_sha1()),
                     "the digest the check reports is the pin's");
        }
    }

    // --- and a file that is not it does not, with a reason that names the number ---
    if bad.len > 1 {
        var bad_path = bad;
        let ok = um_check_file(bad_path[..], um_client_size(), um_client_sha1());
        gf_check(!ok, "a jar that is not the pinned one is refused");
        print("gamefiles: wrong jar refused: ", um_check_reason()[..], "\n");
        gf_check(um_check_reason().len > 0, "the refusal carries a reason");
        // The import path holds a picked file to the same rule.
        let code = um_import_verdict(bad_path[..], 12345);
        gf_check(code == 0, "the import path refuses it too");
        gf_check(um_import_message().len > 0, "and says why");
        print("gamefiles: import refused: ", um_import_message()[..], "\n");
        if good_path.len > 1 {
            let good_code = um_import_verdict(good_path[..], 12345);
            gf_check(good_code == 1, "the import path accepts the pinned jar");
            print("gamefiles: import accepted: ", um_import_message()[..], "\n");
        }
    }

    // --- the paths the app uses are the ones jar_try() looks for ---------------
    var jar = um_jar_path("/data/user/0/org.umbra.client/files");
    print("gamefiles: jar path ", jar[..], "\n");
    gf_check(ends_with(jar[..], "/client.jar"),
             "the jar the flow writes is the client.jar jar_try() already reads");
    var part = um_part_path("/x");
    gf_check(ends_with(part[..], "/client.jar.part"),
             "a download lands somewhere else first, so a crash cannot leave a half jar in use");

    // --- every state the screen can be in has words, and they differ -----------
    // One headline per state, kept in one arena with its offset and length, so
    // "they all say something different" can be checked without six arrays.
    var heads: u8[>..] = [];
    var head_off: i64[6] = [0; 6];
    var head_len: i64[6] = [0; 6];
    var i: i64 = 0;
    while i < 6 {
        let kind = um_state_set(i, um_pinned_size(), um_pinned_size(), "detail");
        gf_check(kind == i, "the state keeps its kind");
        gf_check(um_state_text().len > 0, "a state has a headline");
        gf_check(um_state_detail().len > 0, "and a second line");
        head_off[i] = heads.len;
        head_len[i] = um_state_text().len;
        heads.append(um_state_text());
        i += 1;
    }
    var distinct = 0;
    var a: i64 = 0;
    while a < 6 {
        var same = 0;
        var b: i64 = 0;
        while b < 6 {
            if b != a && head_len[a] == head_len[b] &&
                eq_bytes(heads[head_off[a] .. head_off[a] + head_len[a]],
                         heads[head_off[b] .. head_off[b] + head_len[b]]) { same += 1; }
            b += 1;
        }
        if same == 0 { distinct += 1; }
        a += 1;
    }
    gf_check(distinct == 6, "the six states say six different things");
    // Downloading: the words carry the percentage, so the owner can see it move.
    var _k = um_state_set(UM_ST_DOWNLOADING, um_pinned_size() / 2, um_pinned_size(), "");
    print("gamefiles: downloading says: ", um_state_text()[..], " / ", um_state_detail()[..], "\n");
    gf_check(um_state_text().len > 0 && contains(um_state_text()[..], '%' as u8),
             "the download line carries a percentage");
    _k = um_state_set(UM_ST_FAILED, 0, 0, "the sha1 is wrong");
    gf_check(contains(um_state_detail()[..], 'w' as u8), "a failure shows its reason");

    if gf_failures > 0 {
        print("FAILED gamefiles (", gf_failures, " of ", gf_checks, " checks failed)\n");
        exit(1);
    }
    print("PASS gamefiles (", gf_checks, " checks)\n");
}
