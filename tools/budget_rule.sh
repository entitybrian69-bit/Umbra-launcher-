#!/usr/bin/env bash
# The frame-budget rule from step 1, in one place so both phases and a host test use it.
#
# Step 1 is "no frame blocks over ~50 ms of CPU work", measured by the app over a 45 s walk.
# This emulator's software renderer has a tail: run 44916416450 walked 45 s and reported
# "worst 44.9, 0 over 50 ms", then walked the same window again one phase later on the same
# build and save and reported "worst 58.4, 1 over" -- one run disagreeing with itself, which
# is the proof that a frame or two is the machine and not the code.
#
# So the rule is about the *size* of the breach and whether it repeats, not about whether a
# number is above zero:
#
#   * a walk over budget by NOISE_FRAMES or fewer gets one more 45 s walk on the same app
#     instance (no relaunch, so nothing else changes);
#   * if the repeat is also within that, it is recorded as a tail and the phase passes, with
#     both numbers in the log -- a regression that puts tens of frames over (the cull phase
#     measures 239 over in 746 frames with the cull off) can never pass this way;
#   * anything bigger fails on the first walk, with no retry: that is a regression, and
#     retrying it only costs four minutes;
#   * a verdict that cannot be parsed fails. An unparseable count is a bug in the
#     measurement, and passing it is the defect the window-parse guard exists for.
#
# `budget_verdict` prints one of: clean | retry | tail | regression | unparseable.
NOISE_FRAMES=2

# Every reader of a report goes through these. Two things are deliberate:
#
#   * `${1-}`, because `set -u` turned "no count here" into a dead script once (run
#     44948979735) -- a crash dressed as a verdict;
#   * the *last* match, because a report can arrive with a message in front of it. Run
#     44975224427: `recount` printed its own "retry -- <report>" line to stdout, the caller
#     captured message and report together, `over_count` found two matches, `$OVERS` was
#     "2\n2", `within_noise` was false, and a two-frame tail -- the case the retry exists for
#     -- was reported as a regression.
over_count() { printf '%s' "${1-}" | sed -n 's/.*, \([0-9]*\) over 50 ms.*/\1/p' | tail -1; }
worst_ms()   { printf '%s' "${1-}" | sed -n 's/.*worst \([0-9.]*\) at frame.*/\1/p' | tail -1; }

within_noise() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -le "$NOISE_FRAMES" ] ;;
    esac
}

# budget_verdict <first walk report> [<retry walk report>]
#
# The retry argument is told apart from its absence with $#: a retry that was *asked for* and
# produced no report is a broken measurement, not a quiet pass, and `recount` returning
# nothing is exactly how that happens.
budget_verdict() {
    local first="${1-}" retry n m
    local have_retry=0
    [ "$#" -ge 2 ] && have_retry=1
    [ -n "$first" ] || { echo unparseable; return; }
    case "$first" in
        *"OVER BUDGET"*) ;;
        *) echo clean; return ;;
    esac
    n="$(over_count "$first")"
    case "$n" in
        ''|*[!0-9]*) echo unparseable; return ;;
    esac
    [ "$n" -le "$NOISE_FRAMES" ] || { echo regression; return; }
    [ "$have_retry" = 1 ] || { echo retry; return; }
    retry="${2-}"
    [ -n "$retry" ] || { echo unparseable; return; }
    case "$retry" in
        *"OVER BUDGET"*)
            m="$(over_count "$retry")"
            case "$m" in
                ''|*[!0-9]*) echo unparseable ; return ;;
            esac
            if within_noise "$m"; then echo tail; else echo regression; fi ;;
        *) echo clean ;;
    esac
}

# recount <pid> <label>: one more 45 s walk on the live app instance, then its last report.
# Says what it got, always, so a retry that produced no new walk is visible instead of
# silently re-reading the first one.
recount() {
    local pid="$1" label="$2" again
    adb shell input swipe $(( P_WIDTH / 2 )) "$P_SCENE_Y" $(( P_WIDTH / 2 )) "$P_SCENE_Y" 45000 \
        > /dev/null 2>&1 || say "$label: the retry hold failed"
    sleep 3
    again="$(app_log "$pid" | grep 'walk: .* frame(s) avg ' | tail -1)"
    # The line goes to the log; the report goes to stdout, and nothing else does. A function
    # that both prints a message and returns a value has its output captured by the caller's
    # `$(...)` too, and then the caller measures the message (run 44975224427).
    say "$label: retry -- ${again:-no walk report}" >&2
    printf '%s' "$again"
}
