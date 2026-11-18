#!/usr/bin/env bash
# The window-block extractor tools/gen_window_hook.sh uses, against real readings.
#
# The first case is the reading that failed run 44332432994: a window with 2 668 210
# blocks was called "no blocks" because the test was
#     case "$now" in *"0 non-air blocks"*)
# and that string ends in "0 non-air blocks". Two verdicts about one save disagreed --
# the reader said PASS, the hook said empty -- because one tested a number and the other
# a string. This script keeps both the extractor and the counter-example.
#
# The extractor below must stay identical to the one in gen_window_hook.sh. If you change
# one, change the other; the hook's line is marked with the same comment.
set -u

parse() {
    now="$1"
    blocks="${now##*, }"; blocks="${blocks%% *}"
    case "$blocks" in
        ''|*[!0-9]*) echo "UNPARSEABLE" ;;
        0)           echo "ZERO" ;;
        *)           echo "$blocks" ;;
    esac
}

fail=0
check() {
    got="$(parse "$1")"
    if [ "$got" = "$2" ]; then
        printf 'ok   %-42s -> %s\n' "\"$1\"" "$got"
    else
        printf 'FAIL %-42s -> %s (wanted %s)\n' "\"$1\"" "$got" "$2"
        fail=1
    fi
}

check "81 chunks, 2668210 non-air blocks" 2668210
check "81 chunks, 2668206 non-air blocks" 2668206
check "25 chunks, 101105 non-air blocks" 101105
check "0 chunks, 0 non-air blocks" ZERO
check "4 chunks, 24673 non-air blocks" 24673
check "no window totals" UNPARSEABLE
check "" UNPARSEABLE

# The bug itself, asserted so it cannot be reintroduced as "equivalent".
case "81 chunks, 2668210 non-air blocks" in
    *"0 non-air blocks"*) old=says-empty ;;
    *) old=says-fine ;;
esac
if [ "$old" = says-empty ]; then
    echo "ok   the old substring test does call 2668210 empty (which is why it is gone)"
else
    echo "FAIL the counter-example no longer reproduces; this test has stopped testing"
    fail=1
fi

# And the hook must not still *execute* that test. Comments are allowed to quote the old
# pattern -- they explain why it was wrong -- so the check skips lines whose first
# non-space character is '#'.
hook="$(dirname "$0")/gen_window_hook.sh"
if [ -f "$hook" ] && awk '
        /^[[:space:]]*#/ { next }
        /\*"0 non-air blocks"\*/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$hook"; then
    echo "FAIL gen_window_hook.sh still tests block counts as a substring"
    fail=1
else
    echo "ok   the hook no longer tests a block count with a substring match"
fi

[ "$fail" = 0 ] && echo "PASS: the window block extractor reads real readings"
exit "$fail"
