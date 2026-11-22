#!/usr/bin/env bash
# The frame-budget rule, against the readings that made it necessary.
#
# Step 1 is "no frame blocks over ~50 ms of CPU work" over a 45 s walk, and the readings do
# not agree with themselves: run 44916416450 was clean at "worst 44.9, 0 over 50 ms" in
# `stream-fullsize` and "worst 58.4, 1 over" in `stream-cull` on the same build, save and
# device, one phase later. Run 44942547331 was 2 frames of 876 at 54.4 ms, twice.
#
# So the rule has to answer one question -- "is this the machine's tail or a regression?" --
# and the answer must not be a judgement call made while staring at a failed log at
# midnight. This runs that function over every reading this project has on file.
#
# usage: tools/test_budget_rule.sh        (exit 0 = the rule classifies them all correctly)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The rule's own file, sourced the way the smoke script sources it.
. "$ROOT/tools/budget_rule.sh"

fail=0
check() {
    local want="$1" first="$2" retry="${3-__none__}"
    local got
    if [ "$retry" = "__none__" ]; then
        got="$(budget_verdict "$first")"
    else
        got="$(budget_verdict "$first" "$retry")"
    fi
    if [ "$got" = "$want" ]; then
        printf 'ok   %-14s %s\n' "$got" "$(printf '%s' "$first" | sed 's/.*walk: //' | cut -c1-96)"
    else
        printf 'FAIL got %-10s wanted %-10s %s\n' "$got" "$want" "$(printf '%s' "$first" | sed 's/.*walk: //' | cut -c1-96)"
        fail=1
    fi
}

# ---- clean: the walk never broke the budget ----------------------------------------
check clean "19:19:52 walk: 1051 frame(s) avg 22.9 ms (43 fps), median 22.8, 1% low 40.1 (24 fps), worst 41.8 at frame 965, 0 over 50 ms"
check clean "19:22:47 walk: 1040 frame(s) avg 22.9 ms, worst 43.9 at frame 212, 0 over 50 ms"
# A worst *above* 50 with a count of 0 cannot happen from the app, but if it ever does the
# count is the verdict and the worst number is not: the app counts, this reads the count.
check clean "walk: 900 frame(s) avg 20 ms, worst 55.0 at frame 3, 0 over 50 ms"

# ---- a tail: one or two frames, the same reading twice ------------------------------
check retry "19:19:56 walk: 1018 frame(s) avg 23.6 ms, worst 44.9 at frame 500, 1 over 50 ms -- OVER BUDGET"
check tail  "19:19:56 walk: 1018 frame(s) avg 23.6 ms, worst 58.4 at frame 223, 1 over 50 ms -- OVER BUDGET" \
            "19:19:56 walk: 1045 frame(s) avg 23.1 ms, worst 52.0 at frame 900, 1 over 50 ms -- OVER BUDGET"
# The run that forced this rule: 2 of 876 at 54.4 ms, and it repeated.
check tail  "20:09:06 walk: 876 frame(s) avg 28.1 ms (35 fps), median 27.6, 1% low 48.1 (20 fps), worst 54.4 at frame 626, 2 over 50 ms -- OVER BUDGET" \
            "20:09:06 walk: 890 frame(s) avg 27.8 ms, worst 53.9 at frame 40, 2 over 50 ms -- OVER BUDGET"
# And a tail that came back clean on the second walk is the clean-walk story, not a tail.
check clean "walk: 1000 frame(s) avg 23.0 ms, worst 56.0 at frame 9, 1 over 50 ms -- OVER BUDGET" \
            "walk: 1002 frame(s) avg 22.9 ms, worst 44.0 at frame 900, 0 over 50 ms"

# ---- a regression: too many frames, so no retry is spent on it ----------------------
check regression "19:21:20 walk: 746 frame(s) avg 48.0 ms (20 fps), median 47.8, 1% low 69.8 (14 fps), worst 76.0 at frame 203, 239 over 50 ms -- OVER BUDGET"
check regression "walk: 800 frame(s) avg 40.0 ms, worst 90.0 at frame 3, 3 over 50 ms -- OVER BUDGET"
# 3 over is over the noise bound, and must fail on the first walk -- no retry spent.
check regression "walk: 800 frame(s) avg 40.0 ms, worst 60.0 at frame 3, 3 over 50 ms -- OVER BUDGET" \
                 "walk: 800 frame(s) avg 40.0 ms, worst 60.0 at frame 3, 3 over 50 ms -- OVER BUDGET"
# A tail that got *worse* on the retry is a regression, not a tail.
check regression "walk: 900 frame(s) avg 23.0 ms, worst 52.0 at frame 3, 1 over 50 ms -- OVER BUDGET" \
                 "walk: 900 frame(s) avg 23.0 ms, worst 61.0 at frame 3, 40 over 50 ms -- OVER BUDGET"

# ---- an unreadable verdict is a failure, never a pass -------------------------------
# This is the window-parse defect in its budget form: a check that cannot read the number
# must not read the absence of a number as "none over".
check unparseable "walk: OVER BUDGET"
check unparseable ""
check unparseable "walk: 900 frame(s) avg 23.0 ms, worst 52.0 at frame 3, 1 over 50 ms -- OVER BUDGET" ""

# ---- the parser ---------------------------------------------------------------------
if [ "$(over_count "walk: 9 frame(s), worst 55.0 at frame 1, 12 over 50 ms")" = 12 ] \
   && [ "$(worst_ms "walk: 9 frame(s), worst 55.5 at frame 1, 12 over 50 ms")" = "55.5" ]; then
    printf 'ok   %-14s count and worst both read from the app'"'"'s own line\n' "parsers"
else
    printf 'FAIL %-14s over_count/worst_ms did not read the app'"'"'s line\n' "parsers"
    fail=1
fi

# ---- and the parser fed what `recount` actually returns ------------------------------
# Run 44975224427: `recount` printed its "retry -- <report>" line to stdout as well as
# returning the report, so the caller captured both, `over_count` found two matches, `$OVERS`
# was "2\n2", `within_noise` was false, and a two-frame tail -- the case the retry exists
# for -- was called a regression. Two guards, one on each side of that:
#   * `over_count` takes the last match, so a message and a report in one string is fine;
#   * `recount` writes its message to stderr, so stdout is only ever the report.
double='retry -- 02:40:16 walk: 866 frame(s) avg 27.7 ms, worst 51.3 at frame 701, 2 over 50 ms -- OVER BUDGET
02:40:16 walk: 866 frame(s) avg 27.7 ms, worst 51.3 at frame 701, 2 over 50 ms -- OVER BUDGET'
# One line out, not two: a message and a report in one capture must read as a single count.
if [ "$(over_count "$double" | wc -l)" -eq 0 ] && [ "$(over_count "$double")" = 2 ] \
   && within_noise "$(over_count "$double")"; then
    printf 'ok   %-14s a message and a report in one capture still reads 2\n' "double capture"
else
    printf 'FAIL %-14s over_count gave "%s", so a two-frame tail would read as a regression\n' \
        "double capture" "$(over_count "$double" | tr '\n' ',')"
    fail=1
fi
# And the other side of it: `recount`'s stdout is exactly the report.
want_report="walk: 866 frame(s) avg 27.7 ms, worst 51.3 at frame 701, 2 over 50 ms -- OVER BUDGET"
if [ "$(ROOT="$ROOT" WANT="$want_report" bash -c '. "$ROOT/tools/budget_rule.sh"; P_WIDTH=1; P_SCENE_Y=1
        adb() { :; }; sleep() { :; }
        app_log() { printf "%s" "$WANT"; }
        out="$(recount 1 label 2>/dev/null)"; printf "%s" "$out"')" = "$want_report" ]; then
    printf 'ok   %-14s stdout carries the report and nothing else\n' "recount"
else
    printf 'FAIL %-14s recount put its message on stdout, which the caller measures\n' "recount"
    fail=1
fi

[ "$fail" = 0 ] && echo "PASS: the budget rule separates this emulator's tail from a regression" \
                || echo "FAILED: the budget rule misclassifies a reading above"
exit "$fail"
