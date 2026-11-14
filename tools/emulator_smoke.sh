#!/usr/bin/env bash
# Umbra emulator smoke test.
#
# Installs the release APK on a headless x86_64 emulator, launches it, waits for
# the world screen, reads the app's own log lines, taps the in-app self-test
# button, captures two screenshots, then soaks the process for a minute and
# checks that it is still alive with no fatal exception in logcat.
#
# Every phase reports through GitHub annotation commands. That is deliberate:
# the annotations of a check run are the one piece of CI output this project can
# read back reliably, so a failure here explains itself without the job log.
#
# Usage: tools/emulator_smoke.sh [path-to.apk]
set -uo pipefail

API="${UMBRA_EMU_API:-30}"
IMAGE="system-images;android-${API};google_apis;x86_64"
AVD="umbra_ci"
BOOT_TIMEOUT="${UMBRA_BOOT_TIMEOUT:-600}"
SOAK_SECONDS="${UMBRA_SOAK_SECONDS:-60}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
PHASE="startup"

esc() { printf '%s' "$1" | tr '\r\n' '  ' | sed 's/%/%25/g' | cut -c1-900; }
note() { echo "::notice title=umbra::$*"; }
err() { echo "::error title=umbra::$*"; }

phase() { PHASE="$1"; note "phase: $PHASE"; }
die() {
    err "$PHASE: $(esc "$1")"
    if [ -f "$PHASE.log" ]; then
        err "$PHASE: log tail: $(esc "$(tail -c 700 "$PHASE.log")")"
    fi
    exit 1
}
# run_phase <name> <command...>: runs a command, keeps its output in <name>.log,
# and turns a non-zero status into one annotation carrying the tail of that log.
run_phase() {
    local name="$1"; shift
    PHASE_RUNNING="$name"
    note "running: $name"
    if ! "$@" > "$name.log" 2>&1; then
        PHASE="$name"
        die "command failed: $*"
    fi
    echo "-- $name --"
    tail -5 "$name.log"
}

[ -n "$SDK" ] || { err "startup: neither ANDROID_SDK_ROOT nor ANDROID_HOME is set"; exit 1; }
note "sdk: $SDK"
export PATH="$SDK/platform-tools:$SDK/emulator:$SDK/cmdline-tools/latest/bin:$PATH"
ADB="$(command -v adb || echo "$SDK/platform-tools/adb")"
EMU="$(command -v emulator || echo "$SDK/emulator/emulator")"

APK="${1:-}"
if [ -z "$APK" ]; then
    APK="$(find . -name '*.apk' -not -path './android/app/build/intermediates/*' | head -1)"
fi
[ -f "$APK" ] || { PHASE="startup"; die "no APK to install (looked for *.apk)"; }
note "apk: $APK ($(stat -c%s "$APK") bytes, sha256 $(sha256sum "$APK" | cut -c1-16))"

# ---- 1. hardware virtualisation -------------------------------------------------
phase "kvm"
VIRT="$(grep -cE '(vmx|svm)' /proc/cpuinfo || true)"
note "kvm: /dev/kvm $(ls -l /dev/kvm 2>&1 | cut -c1-60); cpu flags containing vmx/svm: $VIRT"
if [ ! -e /dev/kvm ]; then
    note "kvm: missing, the emulator will run without acceleration (slow)"
fi

# ---- 2. emulator packages -------------------------------------------------------
phase "sdk-packages"
if [ ! -f "$SDK/platform-tools/adb" ]; then
    run_phase sdk-packages bash -c "yes | sdkmanager --licenses > /dev/null 2>&1; sdkmanager --install 'platform-tools'"
fi
if [ ! -d "$SDK/system-images/android-$API/google_apis/x86_64" ]; then
    run_phase sdk-image bash -c "yes | sdkmanager --licenses > /dev/null 2>&1; sdkmanager --install '$IMAGE' 'emulator'"
else
    note "sdk: $IMAGE already installed"
fi
command -v avdmanager > /dev/null || die "avdmanager is not on PATH"

# ---- 3. AVD ---------------------------------------------------------------------
phase "avd"
# avdmanager and the emulator binary only agree on where an AVD lives if the
# location is stated once. The runner image sets neither variable for us.
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"
echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" --force \
    -p "$ANDROID_AVD_HOME/$AVD.avd" > avd.log 2>&1 \
    || die "avdmanager could not create the AVD: $(tail -c 400 avd.log)"
note "avd: home $ANDROID_AVD_HOME, contents: $(ls "$ANDROID_AVD_HOME" 2>&1 | tr '\n' ' ' | cut -c1-240)"
"$EMU" -list-avds > avds.log 2>&1 || true
note "avd: emulator -list-avds reports: $(tr '\n' ' ' < avds.log | cut -c1-240)"
grep -qx "$AVD" avds.log || die "the emulator does not see AVD $AVD; it lists: $(tr '\n' ' ' < avds.log | cut -c1-240)"

# ---- 4. boot --------------------------------------------------------------------
phase "emulator-boot"
[ -x "$EMU" ] || die "no emulator binary at $EMU"
"$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -netdelay none -netspeed full \
    > emulator.log 2>&1 &
EMU_PID=$!
note "emulator: pid $EMU_PID"

BOOTED=0
DEADLINE=$((SECONDS + BOOT_TIMEOUT))
while [ $SECONDS -lt $DEADLINE ]; do
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        die "the emulator process exited before boot; log tail: $(tail -c 500 emulator.log)"
    fi
    STATE="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
    if [ "$STATE" = "1" ]; then BOOTED=1; break; fi
    sleep 5
done
[ "$BOOTED" = 1 ] || die "no boot within ${BOOT_TIMEOUT}s"
"$ADB" wait-for-device > /dev/null 2>&1
note "emulator: booted after $SECONDS s; $( "$ADB" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r\n') api $("$ADB" shell getprop ro.build.version.sdk | tr -d '\r\n')"
WM_SIZE="$("$ADB" shell wm size | tr -d '\r' | awk '/Physical size/{print $3}' | tail -1)"
note "display: physical size ${WM_SIZE:-unknown}"

# ---- 5. install and launch ------------------------------------------------------
phase "install"
"$ADB" install -r -g "$APK" > install.log 2>&1 || die "adb install failed: $(tail -c 400 install.log)"
note "install: $(tail -1 install.log)"

phase "launch"
"$ADB" shell am start -W -n org.umbra.client/android.app.NativeActivity > launch.log 2>&1 \
    || die "am start failed: $(tail -c 400 launch.log)"
note "launch: $(grep -E 'Status|TotalTime|Error' launch.log | head -3 | tr '\n' ' ')"
sleep 20

PID="$("$ADB" shell pidof org.umbra.client 2>/dev/null | tr -d '\r\n')"
[ -n "$PID" ] || {
    "$ADB" logcat -d > logcat-full.txt 2>&1
    die "the app is not running; last log lines: $(grep -iE 'umbra|FATAL|AndroidRuntime' logcat-full.txt | tail -c 700)"
}
note "running: pid $PID"

# The app writes its own diagnostics through umbra_log(); read them back.
"$ADB" logcat -d -s umbra:V > logcat-umbra.txt 2>&1
note "app log: $(grep -c . logcat-umbra.txt) lines"
i=0
while IFS= read -r line; do
    case "$line" in
        *umbra*) note "app: $(esc "${line#*umbra: }")" ;;
    esac
    i=$((i + 1))
    [ $i -ge 12 ] && break
done < logcat-umbra.txt

# ---- 6. screenshots -------------------------------------------------------------
phase "screenshot-home"
"$ADB" exec-out screencap -p > shot1.png || die "screencap failed"
S1="$(stat -c%s shot1.png)"
[ "$S1" -gt 20000 ] || die "shot1.png is only $S1 bytes, the capture is empty"
note "shot1: $S1 bytes, sha256 $(sha256sum shot1.png | cut -c1-16)"

# The home screen stacks three buttons above the bottom inset; the self test is
# the top one. Its height is 34 logical units with 8 between, measured in the
# app's own pixel space, so the tap is derived from the reported display size.
W="${WM_SIZE%x*}"
H="${WM_SIZE#*x}"
TAP_X=$((W / 2))
TAP_Y=$((H - 117))
phase "selftest-tap"
note "tap: $TAP_X,$TAP_Y (self-test button, from display ${W}x${H})"
"$ADB" shell input tap "$TAP_X" "$TAP_Y" > tap.log 2>&1 || die "input tap failed"
sleep 8
"$ADB" exec-out screencap -p > shot2.png || die "second screencap failed"
S2="$(stat -c%s shot2.png)"
[ "$S2" -gt 20000 ] || die "shot2.png is only $S2 bytes, the capture is empty"
note "shot2: $S2 bytes, sha256 $(sha256sum shot2.png | cut -c1-16)"
"$ADB" logcat -d -s umbra:V > logcat-umbra2.txt 2>&1
note "selftest: $(grep -i 'selftest' logcat-umbra2.txt | tail -3 | tr '\n' '|' | cut -c1-600)"

# ---- 7. soak --------------------------------------------------------------------
phase "soak"
"$ADB" shell dumpsys meminfo org.umbra.client > meminfo.txt 2>&1 || true
note "soak: starting ${SOAK_SECONDS}s"
sleep "$SOAK_SECONDS"
PID2="$("$ADB" shell pidof org.umbra.client 2>/dev/null | tr -d '\r\n')"
"$ADB" logcat -d > logcat-full.txt 2>&1
[ -n "$PID2" ] || die "the app died during the ${SOAK_SECONDS}s soak (pid was $PID)"
note "soak: survived ${SOAK_SECONDS}s, pid $PID2"
if grep -q "FATAL EXCEPTION" logcat-full.txt; then
    die "FATAL EXCEPTION in logcat: $(grep -A6 'FATAL EXCEPTION' logcat-full.txt | tail -c 700)"
fi
note "soak: no FATAL EXCEPTION"
note "meminfo: $(grep -E 'TOTAL PSS|Native Heap' meminfo.txt | tr -s ' ' | tr '\n' '|' | cut -c1-300)"

"$ADB" emu kill > /dev/null 2>&1 || true
note "done: both screenshots captured, no crash"
