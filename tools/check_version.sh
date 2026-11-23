#!/usr/bin/env bash
# One version, in one place, or the build says so.
#
# `UMBRA_APP_VERSION` in `platform/shared/umbra_app.h` is what the app's top line
# prints. `UMBRA_VERSION` in `goose/main.goose` is what the core reports through
# `umbra_version()`. They were allowed to drift, and did: the header said 0.3.10
# and the core said 0.3.9 while a release was being prepared, so a phone would have
# shown one number on its HUD and a different one in the core's own report. Nothing
# caught it, because nothing compared them.
#
# This also checks the tag being released, when one is given: `--tag v0.3.10-pre`
# insists the version is 0.3.10, so a release cannot be cut from a tree that forgot
# to bump, and a bump with no tag is caught by the same comparison in CI.
#
# usage: tools/check_version.sh [--tag v0.3.10-pre]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="${2:-}"; shift 2 ;;
        *) echo "check_version: unknown argument $1" >&2; exit 2 ;;
    esac
done

FAILED=0
fail() { printf 'FAIL %-12s %s\n' "$1" "$2"; FAILED=1; }
ok()   { printf 'ok   %-12s %s\n' "$1" "$2"; }

APP="$(sed -n 's/^#define UMBRA_APP_VERSION "\([^"]*\)".*/\1/p' platform/shared/umbra_app.h)"
CORE="$(sed -n 's/^let UMBRA_VERSION = "\([^"]*\)";.*/\1/p' goose/main.goose)"

case "$APP" in
    ''|[0-9]*.[0-9]*.[0-9]*) ok app "$APP (platform/shared/umbra_app.h, the top line)" ;;
    *) fail app "UMBRA_APP_VERSION is '$APP', which is not a version" ;;
esac
case "$CORE" in
    ''|[0-9]*.[0-9]*.[0-9]*) ok core "$CORE (goose/main.goose, umbra_version())" ;;
    *) fail core "UMBRA_VERSION is '$CORE', which is not a version" ;;
esac

if [ -n "$APP" ] && [ "$APP" = "$CORE" ]; then
    ok match "both say $APP, so the HUD and the core cannot disagree"
else
    fail match "the header says '${APP:-nothing}' and the core says '${CORE:-nothing}'"
fi

# The jar-based and other places a version is written down. Each is a place that has
# been stale at least once in this project's history.
ANDROID="$(sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' android/app/build.gradle* 2>/dev/null | head -1)"
if [ -n "$ANDROID" ]; then
    if [ "$ANDROID" = "$APP" ]; then
        ok android "versionName $ANDROID"
    else
        fail android "the APK's versionName is $ANDROID but the app says $APP"
    fi
fi

if [ -n "$TAG" ]; then
    # v0.3.10-pre -> 0.3.10
    WANT="${TAG#v}"
    WANT="${WANT%%-*}"
    if [ "$WANT" = "$APP" ]; then
        ok tag "$TAG is version $APP"
    else
        fail tag "$TAG is version $WANT but the tree says ${APP:-nothing}"
    fi
fi

[ "$FAILED" = 0 ] && echo "PASS: the version is one number"
[ "$FAILED" = 0 ] || echo "FAILED: the build says more than one version of itself"
exit "$FAILED"
