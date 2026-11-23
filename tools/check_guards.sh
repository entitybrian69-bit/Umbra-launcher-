#!/usr/bin/env bash
# The guards that were only in build/gate.sh, which is git-ignored.
#
# The point of this file is that CI runs exactly what a local gate runs. build/gate.sh
# stayed in build/ by accident: build/ is ignored because it holds generated output, and a
# convenience script written next to that output never got moved. So two guards that have
# each caught a real defect -- the zip layout rule and the window block parser -- were
# never run by anything but one machine.
#
# usage: tools/check_guards.sh        (exit 0 = all guards pass)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0

guard() {
    local name="$1"; shift
    if "$@" > "/tmp/guard-$name.log" 2>&1; then
        printf 'ok   %-18s %s\n' "$name" "$(tail -1 "/tmp/guard-$name.log")"
    else
        printf 'FAIL %-18s %s\n' "$name" "$(tail -3 "/tmp/guard-$name.log" | tr '\n' ' ')"
        fail=1
    fi
}

# Each of these has a defect behind it:
#   window_parse  - a substring test called "2668210 non-air blocks" an empty window,
#                   twelve times, in the same step where the reader printed PASS.
#   zip_world     - two overworld layouts with the same file names collided in the archive
#                   and the stale one won, so the phone opened proto-chunks.
#   workflows     - a heredoc at column 0 inside `run: |` stopped a workflow being YAML, and
#                   a run failed in 0 seconds with zero jobs.
guard window_parse  bash tools/test_window_parse.sh
guard open_line     bash tools/test_open_line_parse.sh
guard zip_world     python3 tools/zip_world.py --selftest
guard workflows     python3 tools/check_workflows.py
guard hook_syntax   bash -n tools/gen_window_hook.sh
guard smoke_syntax  bash -n tools/emulator_smoke.sh
#   crash_ours    - run 44432932868's soak failed on another preinstalled app's crash
#                   (YouTube Music's empty version string) while this app was alive with
#                   the right pid. The check is now a function, and this tests it.
guard crash_ours    bash tools/test_crash_ours.sh
guard evidence_syn  bash -n tools/commit_evidence.sh
#   gallery       - run 44938399066 posed the gallery at y 320 in a world whose ground stops at
#                   y 91 (a section index read as a height) and then failed a byte-count gate
#                   that called a valid sky shot "not a picture". Both are host-checkable.
guard gallery       bash tools/test_gallery_poses.sh
#   budget        - run 44916416450 said 0 over and 1 over about the same walk on the same
#                   build, one phase apart; run 44942547331 said 2 over, twice. Whether that
#                   is the emulator's tail or a step-1 regression is a rule, and the rule is
#                   a function, so it is tested against every reading on file.
guard budget        bash tools/test_budget_rule.sh
#   budget_phases  - run 44948979735 died on a 2-frame breach -- the number the retry exists
#                    for -- because `$OVERS` was assigned inside the retry branch and read in
#                    the message that opened it. `set -u` made that a dead script, `bash -n`
#                    cannot see it, and the summary ended mid-phase. This runs both phases
#                    against stubs, so every branch is executed rather than parsed.
guard budget_phases bash tools/test_budget_phases.sh
#   smoke_order   - run 44984148148 died on a 49-frame budget breach and *that was the end of
#                    the run*: `stream-where`, the only phase whose split is raster time
#                    rather than enqueue time, is four phases later and never ran, so the
#                    breach arrived with a number and no explanation -- which is how six
#                    attempts each became a guess. A breach now defers: the run still fails,
#                    but the phase that explains it runs first. This checks that order, and
#                    that a deferred failure is still fatal at the end.
guard smoke_order  bash tools/test_smoke_order.sh
#   version       - the header said 0.3.10 and the Goose core said 0.3.9 while a release was
#                   being prepared, so the phone's HUD and the core's own report would have
#                   disagreed about which build was running. Nothing compared them.
guard version      bash tools/check_version.sh
#   gallery_page  - the page is generated from whatever pictures are committed, so it can
#                   show a picture that is not there or claim a count it does not have --
#                   the gallery's own README said "7 picture(s)" beside a list of one, and
#                   the shot gate once passed a flat frame. Tested against both.
guard gallery_page bash tools/test_gallery_page.sh

#   c_compiles    - platform/shared/umbra_app.c is one file with two platform branches
#                   behind #ifdef __ANDROID__, and only one of them is compiled by any
#                   given build. A change to the game-files screen that type-checks on the
#                   host and not for Android costs ten minutes of CI to discover, which is
#                   exactly what happened before this guard existed.
if [ -x build/bin/goose ] || command -v goose > /dev/null 2>&1; then
    guard c_compiles    env GOOSE="${GOOSE:-build/bin/goose}" bash tools/check_c.sh
else
    printf 'skip %-18s no goose compiler; run tools/pin_goose.sh\n' c_compiles
fi

[ "$fail" = 0 ] && echo "PASS: every guard passed" || echo "FAILED: a guard above did not pass"
exit "$fail"
