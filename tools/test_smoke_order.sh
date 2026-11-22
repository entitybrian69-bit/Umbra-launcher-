#!/usr/bin/env bash
# The harness's failure order, executed rather than parsed.
#
# Run 44984148148 died in `stream-fullsize` on
#
#     49 frames broke the 50 ms CPU budget ... scene 87.0, cutout 38.7
#
# and that is where the run ended. `stream-where` -- four phases later, and the only phase
# with a glFinish per pass, so the only one whose split is raster time rather than enqueue
# time -- never ran, and neither did the gallery. The run reported a number and no
# explanation, which is how the previous six attempts each became a guess.
#
# The rule now: a budget breach is *deferred* (the run still fails, at the end), the
# attribution phase runs, and the phases before it stop. This test runs the extracted
# control flow with a stub that records the order things happened in, so the rule is a fact
# about the script rather than a comment in it.
#
# usage: tools/test_smoke_order.sh        (exit 0 = the order is right)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SMOKE="$ROOT/tools/emulator_smoke.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# The four markers, in the file, in the order they have to behave: the phase that measures
# the budget, the two that follow it, and the one that explains it.
python3 - "$SMOKE" <<'PY'
import sys
src = open(sys.argv[1]).read()
lines = src.splitlines(True)

def stripped(i):
    return lines[i].strip()

def refuse(phase):
    """The line index of the `deferred_fail` that guards `phase`, if it has one."""
    hit = next(i for i, l in enumerate(lines) if stripped(i) == 'section "%s"' % phase)
    # The guard is the statement immediately before it (there may be a comment between).
    j = hit - 1
    while j >= 0 and (stripped(j).startswith('#') or stripped(j) == ''):
        j -= 1
    return (j, hit) if stripped(j) == 'deferred_fail' else (None, hit)

cull, cull_section = refuse('stream-cull')
gallery, gallery_section = refuse('gallery')
where, where_section = refuse('stream-where')
assert cull is not None, 'stream-cull can run after a deferred failure'
assert gallery is not None, 'gallery can run after a deferred failure'
assert where is None, 'stream-where refuses to run, and it is the phase that explains the breach'
assert 'no `deferred_fail` here' in ''.join(lines[where_section - 3:where_section + 1]), \
    'stream-where must say why it runs despite a deferred failure'
assert cull_section < where_section < gallery_section, \
    'the phases are out of order: cull %d, where %d, gallery %d' % (
        cull_section, where_section, gallery_section)

# And the deferred failure must be fatal at the end, or it is not a failure.
tail = ''.join(lines[-14:])
assert 'deferred_fail' in tail, 'the script can end without reporting a deferred failure'
assert tail.index('deferred_fail') < tail.index('result: PASS'), \
    'the PASS line is printed before the deferred failure is reported'
print('ok')
PY
[ $? = 0 ] || { printf 'FAIL %-24s the phase order is wrong\n' "order"; fail=1; }

# Now the behaviour: the real `defer`/`deferred_fail`, extracted from the script by their
# own function bodies, with a recorder. A copy would pass while the file was broken.
python3 - "$SMOKE" "$TMP/defer.sh" <<'PY'
import sys
src = open(sys.argv[1]).read().splitlines(True)

def body(name):
    start = next(i for i, l in enumerate(src) if l.startswith(name + '()'))
    depth = 0
    for i in range(start, len(src)):
        depth += src[i].count('{') - src[i].count('}')
        if depth == 0 and i > start:
            return ''.join(src[start:i + 1])
    raise AssertionError(name + ': no closing brace')

out = ''.join(body(n) for n in ('deferred_fail', 'defer'))
assert 'DEFERRED' in out and 'exit 1' in out
open(sys.argv[2], 'w').write(out)
PY

cat > "$TMP/run.sh" <<'SH'
set -uo pipefail
DEFERRED=""
PHASE="stream-fullsize"
err() { printf 'err: %s\n' "$*"; }
exit() { printf 'exit %s\n' "$1"; return 0; }   # don't really exit
. "$1"
printf 'deferred_fail (nothing pending): '; deferred_fail; printf 'continued\n'
defer "the budget was breached"
defer "and something else"
printf 'deferred_fail (two pending): '; deferred_fail
printf 'DEFERRED=%s\n' "$DEFERRED"
SH
out="$(bash "$TMP/run.sh" "$TMP/defer.sh" 2>&1)"
case "$out" in
    *"deferred_fail (nothing pending): continued"*)
        printf 'ok   %-24s an empty deferral does not stop the run\n' "defer" ;;
    *)  printf 'FAIL %-24s an empty deferral stopped the run: %s\n' "defer" "$out"; fail=1 ;;
esac
case "$out" in
    *"err: stream-fullsize: the budget was breached; stream-fullsize: and something else"*"exit 1"*)
        printf 'ok   %-24s every deferred failure is reported, then the run exits 1\n' "defer" ;;
    *)  printf 'FAIL %-24s the deferred failures were lost: %s\n' "defer" "$out"; fail=1 ;;
esac

if bash -n "$SMOKE"; then
    printf 'ok   %-24s the smoke script still parses\n' "syntax"
else
    printf 'FAIL %-24s the smoke script does not parse\n' "syntax"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS: a budget breach is deferred to the phase that can explain it, and still fails the run"
[ "$fail" = 0 ] || echo "FAILED: the harness would lose a failure or stop before the explanation"
exit "$fail"
