#!/usr/bin/env bash
# Does the soak's crash check tell this app's crash from the emulator's?
#
# Run 44432932868 failed its soak on a FATAL EXCEPTION from
# com.google.android.apps.youtube.music, a preinstalled app whose version string is
# empty in that AVD image. The app under test was alive with the right pid, and the
# summary said so two lines above the failure. That is a check failing for the machine,
# which this project has already paid for once (D-045).
#
# So the check is a function, and this tests the function on all three cases with the
# real log from the run that failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck disable=SC1090
source <(sed -n '/^crash_is_ours()/,/^}/p' tools/emulator_smoke.sh)
command -v crash_is_ours > /dev/null || { echo "FAIL: no crash_is_ours in emulator_smoke.sh"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# 1. The crash from the run that failed the build: another app's, so not ours.
printf '%s\n' \
    'E AndroidRuntime: FATAL EXCEPTION: main' \
    'E AndroidRuntime: Process: com.google.android.apps.youtube.music, PID: 4099' \
    'E AndroidRuntime: java.lang.RuntimeException: Unable to create application' > "$tmp/other.txt"
if crash_is_ours "$tmp/other.txt"; then
    echo "FAIL: another app's crash was called this app's"; fail=1
else
    echo "ok   another app's crash is not ours"
fi

# 2. A crash that is ours: the same shape, with this app's process name.
printf '%s\n' \
    'E AndroidRuntime: FATAL EXCEPTION: main' \
    'E AndroidRuntime: Process: org.umbra.client, PID: 6663' > "$tmp/ours.txt"
if crash_is_ours "$tmp/ours.txt"; then
    echo "ok   this app's crash is ours"
else
    echo "FAIL: this app's own crash was not detected"; fail=1
fi

# 3. No crash at all. The old check was a grep, so this case also has to hold.
printf 'I/umbra: mesh: 243 vertices\n' > "$tmp/none.txt"
if crash_is_ours "$tmp/none.txt"; then
    echo "FAIL: a clean log was reported as a crash"; fail=1
else
    echo "ok   a clean log is not a crash"
fi

# 4. A crash with no Process: line (a truncated buffer) is not silently ours, and not
#    silently fine either -- it is treated as not ours, because the pid check in the
#    soak has already established whether the app is alive.
printf 'E AndroidRuntime: FATAL EXCEPTION: main\n' > "$tmp/trunc.txt"
if crash_is_ours "$tmp/trunc.txt"; then
    echo "FAIL: a crash with no process was attributed to this app"; fail=1
else
    echo "ok   a crash with no process line is not attributed to this app"
fi

[ "$fail" = 0 ] && echo "PASS: the soak's crash check distinguishes this app from the machine" || echo "FAILED"
exit "$fail"
