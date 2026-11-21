#!/usr/bin/env bash
# The budget phases, executed rather than parsed.
#
# Run 44948979735 died in `stream-fullsize` on a walk that was *2 frames over* -- the exact
# number the retry exists for -- because `$OVERS` was assigned inside the retry branch and
# read in the message that opened it. `set -u` turned that into
# `OVERS: unbound variable`, the phase died, and because `err`/`say`/`note` are the only
# things that write to `summary.txt` the failure left no line of its own behind: the summary
# ended mid-phase and the log was the only place the word "unbound" appeared at all.
#
# `bash -n` cannot see this and no host test of `budget_verdict` can either: the bug is in
# how the phases *use* the verdict. So this extracts the two case blocks from
# `tools/emulator_smoke.sh` and runs them against stubbed `say`/`note`/`die`/`app_log`, with
# the readings that make each branch run:
#
#   * a 2-frame breach followed by a clean retry -- the branch that killed 44948979735;
#   * a 2-frame breach followed by another one (the tail);
#   * 40 frames over (a regression, which must die);
#   * a clean walk (no retry, no message that mentions a count).
#
# Every one of them must finish with a verdict and no unbound variable anywhere.
#
# usage: tools/test_budget_phases.sh        (exit 0 = all four behave)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SMOKE="$ROOT/tools/emulator_smoke.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# The two phase bodies, cut out of the smoke script by their own markers so this test cannot
# drift from it: from the line that computes `VERDICT` to the end of the `case`, and the same
# for the cull phase. A copy would pass while the real file was broken.
python3 - "$SMOKE" "$TMP/fullsize.sh" "$TMP/cull.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
lines = src.splitlines(True)

def cut(start_marker, case_open, out):
    """The verdict's lines and the whole `case` they decide -- whichever side it sits on.

    The two phases differ: `stream-fullsize` computes its verdict and then opens the case,
    `stream-cull` opens the case and computes the verdict inside its first branch. Four
    earlier versions of this cut each failed on one of the two, which is the reason the
    extraction asserts what it got: what is run has to be the file's own block, or the test
    passes while the script is broken."""
    v = next(i for i, l in enumerate(lines) if start_marker in l)
    a = next(i for i, l in enumerate(lines) if l.rstrip("\n") == case_open)
    depth, b = 0, None
    for i in range(a, len(lines)):
        t = lines[i].strip()
        if t.startswith("case ") and t.endswith(" in"):
            depth += 1
        elif t == "esac" or t.startswith("esac ;;"):
            depth -= 1
            if depth == 0:
                b = i
                break
    assert b is not None, f"{case_open}: no matching esac"
    body = "".join(lines[min(v, a):b + 1])
    assert start_marker in body, f"{case_open}: the verdict is not in the cut"
    assert "over_count" in body, f"{case_open}: the cut is missing the phase's own lines"
    assert body.count("esac") == 2, f"{case_open}: {body.count('esac')} esac lines, expected 2"
    open(out, "w").write(body)

cut('VERDICT="$(budget_verdict "$REPORT")"', '    case "$REPORT" in', sys.argv[2])
cut('ON_VERDICT="$(budget_verdict "$CULL_ON")"', '    case "$CULL_ON" in', sys.argv[3])
PY

# The stubs a phase needs. `set -u` is on, as in the real script; `die` records the failure
# and exits non-zero, the way the real one does.
cat > "$TMP/stubs.sh" <<'STUB'
set -uo pipefail
. "$ROOT/tools/budget_rule.sh"
OUT=""
say()  { OUT="${OUT}say: $*"$'\n'; }
note() { OUT="${OUT}note: $*"$'\n'; }
die()  { OUT="${OUT}DIE: $*"$'\n'; FAILED=1; }
FAILED=0
ADEV=""
app_log() { printf '%s' "$ADEV"; }
adb() { :; }
P_WIDTH=1920; P_SCENE_Y=900
# The retry: one more walk, which the stub serves from RETRY_LOG.
RETRY_LOG=""
recount() {
    say "$2: retry -- ${RETRY_LOG:-no walk report}"
    ADEV="${ADEV}"$'\n'"${RETRY_LOG}"
    printf '%s' "$RETRY_LOG"
}
STUB

# run_phase <name> <body file> <first report> <retry report>: build a small script out of the
# phase body and the stubs, run it, and report what it decided. The body is taken verbatim
# from `tools/emulator_smoke.sh`, so a variable the body forgets to set is a variable this
# test forgets to set -- which is the point: the failure is "unbound variable", not a wrong
# answer.
run_phase() {
    local name="$1" body="$2" first="$3" retry="$4" out
    {
        printf 'ROOT=%q\n' "$ROOT"
        cat "$TMP/stubs.sh"
        printf 'REPORT=%q\n' "$first"
        printf 'CULL_ON=%q\n' "$first"
        printf 'SPLIT=%q\n' ""
        printf 'RETRY_LOG=%q\n' "$retry"
        printf 'ADEV=%q\n' "$first"
        printf 'ON_PID=1\nFS_PID=1\n'
        cat "$body"
        printf 'printf "%%s" "$OUT"\n'
        printf '[ "$FAILED" = 0 ]\n'
    } > "$TMP/run.sh"
    out="$(bash "$TMP/run.sh" 2>&1)"
    case "$out" in
        *"unbound variable"*)
            printf 'FAIL %-34s unbound variable: %s\n' "$name" "$(printf '%s' "$out" | grep -m1 'unbound')"
            fail=1; return ;;
    esac
    printf '%s\n' "$out" > "$TMP/$name.log"
    printf 'ok   %-34s %s\n' "$name" "$(printf '%s' "$out" | grep -E 'say:|DIE:' | head -1 | cut -c1-96)"
}

BREACH2="21:18:07 walk: 809 frame(s) avg 29.7 ms, worst 51.6 at frame 717, 2 over 50 ms -- OVER BUDGET"
CLEAN="21:20:00 walk: 812 frame(s) avg 24.0 ms, worst 44.0 at frame 10, 0 over 50 ms"
BREACH1="21:20:00 walk: 812 frame(s) avg 24.0 ms, worst 52.0 at frame 10, 1 over 50 ms -- OVER BUDGET"
BIG="21:20:00 walk: 700 frame(s) avg 48.0 ms, worst 90.0 at frame 10, 40 over 50 ms -- OVER BUDGET"

run_phase "fullsize: 2 over, then clean"  "$TMP/fullsize.sh" "$BREACH2" "$CLEAN"
grep -q "one breaching walk and then a clean one" "$TMP/fullsize: 2 over, then clean.log" \
    && printf 'ok   %-34s retried, then accepted the clean walk\n' "fullsize: 2 over, then clean" \
    || { printf 'FAIL %-34s did not reach the clean-walk verdict\n' "fullsize: 2 over, then clean"; fail=1; }

run_phase "cull: 2 over, then clean"      "$TMP/cull.sh"     "$BREACH2" "$CLEAN"
grep -q "one breaching walk and then a clean one" "$TMP/cull: 2 over, then clean.log" \
    && printf 'ok   %-34s retried, then accepted the clean walk\n' "cull: 2 over, then clean" \
    || { printf 'FAIL %-34s did not reach the clean-walk verdict\n' "cull: 2 over, then clean"; fail=1; }

run_phase "fullsize: 2 over, then 2 over"  "$TMP/fullsize.sh" "$BREACH2" "$BREACH2"
grep -q "STILL OVER BUDGET by 2 frame(s)" "$TMP/fullsize: 2 over, then 2 over.log" \
    && printf 'ok   %-34s recorded as the tail\n' "fullsize: 2 over, then 2 over" \
    || { printf 'FAIL %-34s did not record the tail\n' "fullsize: 2 over, then 2 over"; fail=1; }

run_phase "cull: 2 over, then 1 over"      "$TMP/cull.sh"     "$BREACH2" "$BREACH1"
grep -q "STILL OVER BUDGET by 1 frame(s)" "$TMP/cull: 2 over, then 1 over.log" \
    && printf 'ok   %-34s recorded as the tail\n' "cull: 2 over, then 1 over" \
    || { printf 'FAIL %-34s did not record the tail\n' "cull: 2 over, then 1 over"; fail=1; }

run_phase "fullsize: 40 over"              "$TMP/fullsize.sh" "$BIG"     ""
grep -q "DIE:" "$TMP/fullsize: 40 over.log" \
    && printf 'ok   %-34s failed without spending a retry\n' "fullsize: 40 over" \
    || { printf 'FAIL %-34s a 40-frame breach passed\n' "fullsize: 40 over"; fail=1; }

run_phase "fullsize: clean"                "$TMP/fullsize.sh" "$CLEAN"   ""
grep -q "no frame broke the 50 ms CPU budget" "$TMP/fullsize: clean.log" \
    && printf 'ok   %-34s passed\n' "fullsize: clean" \
    || { printf 'FAIL %-34s a clean walk was not accepted\n' "fullsize: clean"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: both budget phases run every branch without an unbound variable" \
                || echo "FAILED: a budget phase above did not behave"
exit "$fail"
