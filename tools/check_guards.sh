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
guard zip_world     python3 tools/zip_world.py --selftest
guard workflows     python3 tools/check_workflows.py
guard hook_syntax   bash -n tools/gen_window_hook.sh
guard smoke_syntax  bash -n tools/emulator_smoke.sh
guard evidence_syn  bash -n tools/commit_evidence.sh

[ "$fail" = 0 ] && echo "PASS: every guard passed" || echo "FAILED: a guard above did not pass"
exit "$fail"
