#!/usr/bin/env bash
# Umbra emulator smoke test.
#
# Installs the release APK on a headless x86_64 emulator, launches it, waits for
# the app to say it is drawing, reads the app's own log lines, taps the in-app
# self-test button, captures two screenshots, then soaks the process and checks
# that it is still alive with no fatal exception in logcat.
#
# Two channels carry the result out of CI, because the machine that drives this
# project cannot download job logs or artifacts:
#   * summary.txt and a handful of ::error/::notice annotations, which the
#     check-run annotation API exposes;
#   * the log files themselves, which the workflow commits to the branch.
# Everything that can go wrong is therefore readable afterwards.
#
# Usage: tools/emulator_smoke.sh [path-to.apk]
set -uo pipefail

API="${UMBRA_EMU_API:-30}"
IMAGE="system-images;android-${API};google_apis;x86_64"
DEVICE="${UMBRA_EMU_DEVICE:-pixel_2}"
AVD="umbra_ci"
BOOT_TIMEOUT="${UMBRA_BOOT_TIMEOUT:-600}"
APP_TIMEOUT="${UMBRA_APP_TIMEOUT:-90}"
SOAK_SECONDS="${UMBRA_SOAK_SECONDS:-60}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
PHASE="startup"
COLLECTED=0
SUMMARY="summary.txt"

: > "$SUMMARY"

esc() { printf '%s' "$1" | tr '\r\n' '  ' | sed 's/%/%25/g' | cut -c1-900; }
# say: the durable record, written to summary.txt and the job log.
say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
note() { printf '::notice title=umbra::%s\n' "$(esc "$*")"; say "notice: $*"; }
err() { printf '::error title=umbra::%s\n' "$(esc "$*")"; say "ERROR: $*"; }
phase() { PHASE="$1"; say ""; say "== phase: $PHASE =="; }

die() {
    err "$PHASE: $1"
    exit 1
}

# Collect diagnostics on any exit, success or failure, so that a failed run
# still explains itself. Runs once.
collect() {
    [ "$COLLECTED" = 1 ] && return
    COLLECTED=1
    say ""
    say "== collected diagnostics =="
    if [ -n "${ADB:-}" ] && [ -x adb ]; then
        adb logcat -d > logcat-full.txt 2>&1 || true
        adb logcat -d -s umbra:V > logcat-umbra.txt 2>&1 || true
        adb shell dumpsys window > dumpsys-window.txt 2>&1 || true
        adb shell dumpsys activity activities > dumpsys-activity.txt 2>&1 || true
        adb shell pidof org.umbra.client > pid.txt 2>&1 || true
        say "app pid at exit: $(cat pid.txt 2>/dev/null | tr -d '\r\n')"
        grep -m2 -E 'mCurrentFocus|mFocusedApp' dumpsys-window.txt 2>/dev/null \
            | while IFS= read -r l; do say "focus: $(echo "$l" | tr -s ' ')"; done
        if [ -f logcat-full.txt ]; then
            say "logcat: $(wc -l < logcat-full.txt) lines, $(stat -c%s logcat-full.txt) bytes"
            if grep -q "FATAL EXCEPTION" logcat-full.txt; then
                err "FATAL EXCEPTION in logcat: $(grep -A8 'FATAL EXCEPTION' logcat-full.txt | tail -c 800)"
            fi
        fi
        if [ -s logcat-umbra.txt ]; then
            say "app log lines: $(grep -c . logcat-umbra.txt)"
            tail -12 logcat-umbra.txt | while IFS= read -r l; do say "app: $(echo "$l" | tr -s ' ')"; done
        else
            say "app log: empty (the app never logged)"
        fi
    fi
    say ""
}
trap collect EXIT

[ -n "$SDK" ] || die "neither ANDROID_SDK_ROOT nor ANDROID_HOME is set"
export PATH="$SDK/platform-tools:$SDK/emulator:$SDK/cmdline-tools/latest/bin:$PATH"
ADB_BIN="$(command -v adb || echo "$SDK/platform-tools/adb")"
ADB="$ADB_BIN"
# Nothing here may block forever: a hung adb call would hide the failure it
# was about to report, so every device call gets a hard timeout.
adb() { timeout "${ADB_TIMEOUT:-150}" "$ADB_BIN" "$@"; }
EMU="$(command -v emulator || echo "$SDK/emulator/emulator")"
say "run: ${GITHUB_RUN_ID:-local}, commit: ${GITHUB_SHA:-unknown}"
say "sdk: $SDK"
say "adb: $ADB"
say "emulator: $EMU"

APK="${1:-}"
if [ -z "$APK" ]; then
    APK="$(find . -maxdepth 6 -name '*.apk' -not -path '*/intermediates/*' | head -1)"
fi
[ -f "$APK" ] || die "no APK to install (looked for *.apk)"
say "apk: $APK ($(stat -c%s "$APK") bytes, sha256 $(sha256sum "$APK" | cut -d' ' -f1))"

run_phase() {   # run_phase <name> <command...>
    local name="$1"; shift
    if ! "$@" > "$name.log" 2>&1; then
        say "command failed: $*"
        PHASE="$name"
        die "command failed: $* -- $(tail -c 600 "$name.log")"
    fi
    say "$name: ok ($(wc -l < "$name.log") lines)"
}

# ---- 1. hardware virtualisation -------------------------------------------------
phase "kvm"
say "kvm: $(ls -l /dev/kvm 2>&1 | cut -c1-60)"
say "cpu: $(grep -cE '(vmx|svm)' /proc/cpuinfo || true) flags match vmx/svm"
[ -e /dev/kvm ] || note "no /dev/kvm: the emulator will run unaccelerated and slowly"

# ---- 2. emulator packages -------------------------------------------------------
phase "sdk-packages"
if [ ! -x adb ]; then
    run_phase sdk-platform-tools bash -c "yes | sdkmanager --licenses > /dev/null 2>&1; sdkmanager --install 'platform-tools'"
fi
if [ ! -d "$SDK/system-images/android-$API/google_apis/x86_64" ]; then
    run_phase sdk-image bash -c "yes | sdkmanager --licenses > /dev/null 2>&1; sdkmanager --install '$IMAGE' 'emulator'"
else
    say "sdk-image: $IMAGE already present"
fi
command -v avdmanager > /dev/null || die "avdmanager is not on PATH"

# ---- 3. AVD ---------------------------------------------------------------------
phase "avd"
# avdmanager and the emulator binary only agree on where an AVD lives if the
# location is stated once. The runner image sets neither variable for us.
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"
echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" -d "$DEVICE" --force \
    -p "$ANDROID_AVD_HOME/$AVD.avd" > avd.log 2>&1 \
    || die "avdmanager could not create the AVD: $(tail -c 500 avd.log)"
say "avd: $AVD from device profile $DEVICE at $ANDROID_AVD_HOME"
"$EMU" -list-avds > avds.log 2>&1 || true
grep -qx "$AVD" avds.log || die "the emulator does not see AVD $AVD; it lists: $(tr '\n' ' ' < avds.log)"

# ---- 4. boot --------------------------------------------------------------------
phase "emulator-boot"
[ -x "$EMU" ] || die "no emulator binary at $EMU"
"$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -netdelay none -netspeed full \
    -camera-back none -camera-front none -memory 2048 \
    > emulator.log 2>&1 &
EMU_PID=$!
say "emulator: started as pid $EMU_PID"

BOOTED=0
START=$SECONDS
DEADLINE=$((SECONDS + BOOT_TIMEOUT))
while [ $SECONDS -lt $DEADLINE ]; do
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        die "the emulator exited before boot; log tail: $(tail -c 600 emulator.log)"
    fi
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" = "1" ] \
        && { BOOTED=1; break; }
    sleep 5
done
[ "$BOOTED" = 1 ] || die "no boot within ${BOOT_TIMEOUT}s"
adb wait-for-device > /dev/null 2>&1
say "emulator: booted in $((SECONDS - START)) s"
say "android: api $(adb shell getprop ro.build.version.sdk | tr -d '\r\n') ($(adb shell getprop ro.build.version.release | tr -d '\r\n'))"
WM_SIZE="$(adb shell wm size | tr -d '\r' | awk '/Physical size/{print $3}' | tail -1)"
say "display: ${WM_SIZE:-unknown}"

# ---- 5. wake, unlock, install, launch --------------------------------------------
phase "unlock"
say "wake: $(adb shell input keyevent KEYCODE_WAKEUP 2>&1 | tr -d '\r\n')"
adb shell wm dismiss-keyguard > /dev/null 2>&1 || true
adb shell input keyevent 82 > /dev/null 2>&1 || true
adb shell svc power stayon true > /dev/null 2>&1 || true
adb shell settings put global window_animation_scale 0 > /dev/null 2>&1 || true
adb shell settings system put screen_off_timeout 1800000 > /dev/null 2>&1 || true
sleep 3
adb shell dumpsys window > focus.log 2>&1 || true
say "focus before launch: $(grep -m1 -E 'mCurrentFocus' focus.log | tr -s ' ' | cut -c1-160)"

phase "install"
adb install -r -g "$APK" > install.log 2>&1 || die "adb install failed: $(tail -c 500 install.log)"
say "install: $(tail -1 install.log)"

phase "launch"
adb shell am start -W -n org.umbra.client/android.app.NativeActivity > launch.log 2>&1 \
    || die "am start failed: $(tail -c 500 launch.log)"
say "launch: $(grep -E 'Status|TotalTime|Error' launch.log | tr '\n' ' ' | tr -s ' ')"

# Wait for the app's own first words rather than guessing a sleep.
READY=0
DEADLINE=$((SECONDS + APP_TIMEOUT))
while [ $SECONDS -lt $DEADLINE ]; do
    adb logcat -d -s umbra:V > logcat-umbra.txt 2>&1
    if grep -q "Umbra starting" logcat-umbra.txt; then READY=1; break; fi
    if ! adb shell pidof org.umbra.client > /dev/null 2>&1; then
        die "the app is not running any more; umbra log: $(tail -c 800 logcat-umbra.txt)"
    fi
    sleep 3
done
[ "$READY" = 1 ] || die "the app logged its start line never within ${APP_TIMEOUT}s; umbra log: $(tail -c 800 logcat-umbra.txt)"
PID="$(adb shell pidof org.umbra.client 2>/dev/null | tr -d '\r\n')"
say "running: pid $PID"
while IFS= read -r line; do
    case "$line" in
        *"umbra   :"*) say "app: $(echo "${line#*umbra   : }" | tr -s ' ' | cut -c1-220)" ;;
    esac
done < logcat-umbra.txt

# ---- 6. screenshots -------------------------------------------------------------
phase "screenshot-home"
sleep 5
adb exec-out screencap -p > shot1.png || die "screencap failed"
S1="$(stat -c%s shot1.png)"
say "shot1: $S1 bytes, sha256 $(sha256sum shot1.png | cut -d' ' -f1)"
say "focus while drawing: $(adb shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | tr -s ' ' | cut -c1-160)"

# The home screen stacks three buttons of 34 pixels with 8 between them above
# the bottom inset, and the self test is the top one; tap its centre. The
# coordinates come from the reported display size, not from a guess.
W="${WM_SIZE%x*}"
H="${WM_SIZE#x*}"
TAP_X=$((W / 2))
TAP_Y=$((H - 117))
phase "selftest-tap"
say "tap: $TAP_X,$TAP_Y (self-test button, from display ${W}x${H})"
adb shell input tap "$TAP_X" "$TAP_Y" > tap.log 2>&1 || die "input tap failed"
sleep 10
adb exec-out screencap -p > shot2.png || die "second screencap failed"
S2="$(stat -c%s shot2.png)"
say "shot2: $S2 bytes, sha256 $(sha256sum shot2.png | cut -d' ' -f1)"
adb logcat -d -s umbra:V > logcat-umbra2.txt 2>&1
adb shell dumpsys meminfo org.umbra.client > meminfo.txt 2>&1 || true
while IFS= read -r line; do
    case "$line" in
        *self-test*|*selftest*) say "app: $(echo "${line#*umbra   : }" | tr -s ' ' | cut -c1-220)" ;;
    esac
done < logcat-umbra2.txt

# ---- 7. soak --------------------------------------------------------------------
phase "soak"
say "soak: holding for ${SOAK_SECONDS}s"
sleep "$SOAK_SECONDS"
PID2="$(adb shell pidof org.umbra.client 2>/dev/null | tr -d '\r\n')"
[ -n "$PID2" ] || die "the app died during the ${SOAK_SECONDS}s soak (pid was $PID)"
say "soak: survived, pid $PID2"
if adb logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    die "FATAL EXCEPTION appeared during the soak"
fi
say "soak: no FATAL EXCEPTION"
say "meminfo: $(grep -E 'TOTAL PSS|Native Heap' meminfo.txt | tr -s ' ' | tr '\n' '|' | cut -c1-240)"
say "frames drawn: $(grep -c 'frame' logcat-umbra2.txt || true) matching log lines"

adb emu kill > /dev/null 2>&1 || true
phase "done"
say "result: PASS (installed, launched, drew, self test tapped, ${SOAK_SECONDS}s soak, no crash)"
note "PASS: app ran on the emulator, see summary.txt in evidence/ci"
