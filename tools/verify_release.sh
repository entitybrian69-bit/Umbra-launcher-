#!/usr/bin/env bash
# Prove a published release: download every asset again from its public URL,
# require HTTP 200, and compare the SHA-256 with the one that was just built.
#
# This exists as a script rather than a workflow fragment because the fragment
# failed silently once (run 43691770806 wrote only a header and exited 1), and a
# script can be run and tested here, including against a local HTTP server.
#
# usage: tools/verify_release.sh <tag> <dist-dir> <report-file>
# env:   BASE_URL   where the assets live (default: the GitHub release URL)
#        ATTEMPTS   how many times to try each asset (default 5)
set -uo pipefail

TAG="${1:?usage: verify_release.sh <tag> <dist-dir> <report-file>}"
DIST="${2:?usage: verify_release.sh <tag> <dist-dir> <report-file>}"
OUT="${3:?usage: verify_release.sh <tag> <dist-dir> <report-file>}"
ATTEMPTS="${ATTEMPTS:-5}"
REPO="${REPO:-entitybrian69-bit/Umbra-launcher-}"
BASE_URL="${BASE_URL:-https://github.com/${REPO}/releases/download/${TAG}}"
SUMS="$DIST/SHA256SUMS"

echo "verify_release: tag=$TAG dist=$DIST out=$OUT"
echo "verify_release: base=$BASE_URL"

{
    echo "release verification"
    echo "tag: $TAG"
    echo "base: $BASE_URL"
    echo "run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID:-local}"
    echo "commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
} > "$OUT"

if [ ! -f "$SUMS" ]; then
    echo "verify_release: no $SUMS, so there is nothing to check" | tee -a "$OUT"
    echo "verify_release: FAIL" | tee -a "$OUT"
    exit 1
fi

FAILED=0
COUNT=0
# Downloads are kept, next to the built assets, so the next step can run them:
# a hash proves a file arrived, only executing it proves it works.
TMP="$DIST/downloaded"
mkdir -p "$TMP"

while IFS= read -r line; do
    [ -n "$line" ] || continue
    SUM="$(printf '%s' "$line" | cut -d' ' -f1)"
    # sha256sum writes "hash  name" (two spaces); cut leaves one, and a URL with
    # a leading space is not a URL. This cost run 43691770806 its verification.
    NAME="$(printf '%s' "$line" | sed 's/^[0-9a-fA-F]\{64\}[ *]*//')"
    [ -n "$NAME" ] || continue
    COUNT=$((COUNT + 1))
    URL="$BASE_URL/$NAME"
    RESULT=MISMATCH
    CODE=000
    GOT=""
    SIZE=0
    attempt=1
    while [ "$attempt" -le "$ATTEMPTS" ]; do
        CODE="$(curl -sSL --retry 2 --retry-delay 2 -o "$TMP/$NAME" -w '%{http_code}' "$URL" 2>/dev/null)"
        SIZE="$(stat -c%s "$TMP/$NAME" 2>/dev/null || echo 0)"
        GOT="$(sha256sum "$TMP/$NAME" 2>/dev/null | cut -d' ' -f1)"
        if [ "$CODE" = "200" ] && [ "$GOT" = "$SUM" ]; then
            RESULT=OK
            break
        fi
        # A release can take a moment to become downloadable; anything short of
        # a matching hash is retried, and the last attempt's numbers are kept.
        echo "verify: $NAME attempt $attempt: http $CODE, size $SIZE, sha $GOT" >&2
        attempt=$((attempt + 1))
        sleep 5
    done
    if [ "$RESULT" != "OK" ]; then FAILED=1; fi
    {
        echo "asset: $NAME"
        echo "  url: $URL"
        echo "  http: $CODE"
        echo "  size: $SIZE bytes"
        echo "  sha256: $GOT"
        echo "  expected: $SUM"
        echo "  result: $RESULT"
    } | tee -a "$OUT"
    if [ "$RESULT" = "OK" ]; then
        echo "::notice title=verify-$NAME::OK http $CODE, sha256 $GOT, $SIZE bytes"
    else
        echo "::error title=verify-$NAME::MISMATCH http $CODE, sha256 $GOT, expected $SUM"
    fi
done < "$SUMS"

if [ "$COUNT" = 0 ]; then
    echo "verify_release: $SUMS lists no assets" | tee -a "$OUT"
    FAILED=1
fi

{
    echo
    if [ "$FAILED" = 0 ]; then
        echo "RESULT: PASS - $COUNT assets re-downloaded from $BASE_URL and every sha256 matched"
    else
        echo "RESULT: FAIL - at least one of $COUNT assets did not match"
    fi
} | tee -a "$OUT"

exit "$FAILED"
