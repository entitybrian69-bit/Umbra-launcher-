#!/usr/bin/env bash
# The gallery page, tested against the failures it exists to prevent.
#
# The page is generated from whatever pictures are committed, so the two things
# that can go wrong are both silent: it can show a picture that is not there, and
# it can claim a count it does not have. The latter is not hypothetical -- the
# gallery's own README said "7 picture(s)" beside a list of one, and the shot gate
# once passed a flat frame. So:
#
#   * every PNG in the directory is named in the page, and nothing else is;
#   * the count comes from the files, not from a constant;
#   * an empty or missing directory is an error, not an empty page;
#   * the page has no scripts, no CDN and a viewport, because it is read on a phone.
#
# usage: tools/test_gallery_page.sh        (exit 0 = the page is honest)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
GEN="$ROOT/tools/gallery_page.py"

check() {  # check <name> <description> <command...>
    local name="$1" desc="$2"; shift 2
    if "$@" > /dev/null 2>&1; then
        printf 'ok   %-14s %s\n' "$name" "$desc"
    else
        printf 'FAIL %-14s %s\n' "$name" "$desc"
        fail=1
    fi
}

# A run's worth of pictures: three poses, one version, one build.
mkdir -p "$TMP/gallery"
python3 - "$TMP/gallery" <<'PY'
import sys, os
# 1x1 PNGs are enough: the generator reads names and sizes, not pixels.
png = bytes.fromhex(
    '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4'
    '890000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082')
for pose in ('hills', 'forest', 'cave'):
    open(os.path.join(sys.argv[1], 'gallery-%s-0.3.10-abc1234.png' % pose), 'wb').write(png)
PY

# 1. A missing directory is an error. On its own, that means the page never ships
#    empty; the default fallback is the bug this file was written after.
python3 "$GEN" --dir "$TMP/nothing-here" --out "$TMP/x.html" > /dev/null 2>&1
[ $? -ne 0 ] && printf 'ok   %-14s a missing directory is an error, not an empty page\n' "empty" \
             || { printf 'FAIL %-14s a missing directory produced a page\n' "empty"; fail=1; }

# 2. All three appear, by name.
python3 "$GEN" --dir "$TMP/gallery" --out "$TMP/page.html" > /dev/null 2>&1
for pose in hills forest cave; do
    grep -q "gallery-$pose-0.3.10-abc1234.png" "$TMP/page.html" \
        && printf 'ok   %-14s %s is on the page\n' "names" "$pose" \
        || { printf 'FAIL %-14s %s is missing from the page\n' "names" "$pose"; fail=1; }
done

# 3. The count is the page's own. Three pictures is "Three", not "Six" -- the
#    mistake the harness README made.
grep -q "Three fixed poses" "$TMP/page.html" \
    && printf 'ok   %-14s the count comes from the files (Three poses)\n' "count" \
    || { printf 'FAIL %-14s the page claims a count it does not have: %s\n' "count" \
         "$(grep -o 'lead">[^<]*' "$TMP/page.html")"; fail=1; }

# 4. No picture is named that is not on disk.
for shown in $(grep -o 'src="[^"]*"' "$TMP/page.html" | sed 's/src="//; s/"$//'); do
    base="$(basename "$shown")"
    [ -f "$TMP/gallery/$base" ] \
        || { printf 'FAIL %-14s the page shows %s, which is not there\n' "phantom" "$base"; fail=1; }
done

# 5. Phone-shaped: a viewport, and nothing that needs a network.
grep -q 'name="viewport"' "$TMP/page.html" \
    && printf 'ok   %-14s it has a viewport, so a phone lays it out\n' "viewport" \
    || { printf 'FAIL %-14s no viewport: a phone would render it at desktop width\n' "viewport"; fail=1; }
# 6. Nothing is *fetched*: no scripts, and no src/href that points off the site.
#    A plain link to the repository is allowed -- it is a thing the reader may click,
#    not a request the page makes to draw itself -- so the check is for `src=` and
#    `@import`, which are the two ways a page reaches out on its own. The first
#    version of this banned any URL at all and failed on the footer's own link,
#    which is the sort of check that gets deleted instead of fixed.
if grep -qiE '<script|src="https?://|@import|url\(https?://' "$TMP/page.html"; then
    printf 'FAIL %-14s it pulls something in from outside\n' "offline"; fail=1
else
    printf 'ok   %-14s no scripts, no CDN, no webfont: it opens from the repository too\n' "offline"
fi

[ "$fail" = 0 ] && echo "PASS: the gallery page shows exactly the pictures that exist, and says so"
[ "$fail" = 0 ] || echo "FAILED: the gallery page would ship a claim it cannot back"
exit "$fail"
