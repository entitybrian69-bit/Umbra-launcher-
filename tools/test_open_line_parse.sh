#!/usr/bin/env bash
# The device test reads the world-open line by position, so the line's shape is a
# contract. This holds the *streamed* line to it.
#
# Run 44295360944 is why this exists in any form: the smoke test took the last "chunks" on
# the line ("not-full chunks 0"), reported "0 chunk(s), 792923 block(s)" about a phone that
# had just opened 25 chunks, and failed the phase. The fix was to read the fields by
# position -- which works only while the line keeps its order and its wording.
#
# A streamed world needed a different sentence from the import's, because the import's
# counters describe a reader that did not run. The first version of that sentence said
# "2606546 non-air blocks" and broke the parser: it looks for `<n> non-air blocks`, and
# it found nothing, so the phase would have died on a line that was more accurate than
# the one it replaced. This checks the line the app actually prints against the reader
# the smoke test actually uses.
set -uo pipefail

# The exact shape umbra_app.c prints for a streamed world. Keep this in step with it: a
# mismatch here is the guard failing, which is the point.
LINE='07:12:15 world: opened: 81 chunk(s) from 4 region file(s), radius 4, non-air blocks 2606546, read errors 0, 2607 chunk(s) parsed by the stream, missing from the save 3400, 11.6 MB of region files, 3029.9 ms'

OPEN_TAIL="${LINE#*opened: }"
W_CHUNKS="${OPEN_TAIL%% *}"
W_BLOCKS="$(printf '%s\n' "$OPEN_TAIL" | awk '{for(i=2;i<=NF;i++) if($i=="blocks" && $(i-1)=="non-air"){print $(i+1); exit}}')"
W_ERRORS="$(printf '%s\n' "$OPEN_TAIL" | awk '{for(i=2;i<=NF;i++) if($i=="errors" && $(i-1)=="read"){print $(i+1); exit}}')"
W_BLOCKS="${W_BLOCKS%,}"; W_ERRORS="${W_ERRORS%,}"

fail() { echo "open-line: FAIL $*"; exit 1; }
case "$W_CHUNKS" in ''|*[!0-9]*) fail "no leading chunk count in '$OPEN_TAIL'" ;; esac
[ "$W_CHUNKS" -gt 0 ] || fail "the chunk count is not positive"
case "${W_BLOCKS:-}" in ''|*[!0-9]*) fail "no '<n> non-air blocks' in the line" ;; esac
[ "$W_BLOCKS" -gt 0 ] || fail "the block count is not positive"
[ "${W_ERRORS:-x}" = 0 ] || fail "read errors is '${W_ERRORS:-absent}', not 0"

# And the same line without the streamed fields -- the import's own shape -- still parses,
# because a build with streaming off has to keep working.
LINE2='07:12:15 world: opened: 25 chunk(s) from 4 region file(s) -- files 4, entries 4, chunks 25, non-air blocks 792923, states 600, read errors 0, not-full chunks 0, left out 1200, 811.9 ms'
T2="${LINE2#*opened: }"
C2="${T2%% *}"
B2="$(printf '%s\n' "$T2" | awk '{for(i=2;i<=NF;i++) if($i=="blocks" && $(i-1)=="non-air"){print $(i+1); exit}}')"
# The smoke test strips one trailing comma from these fields (`W_BLOCKS="${W_BLOCKS%,}"`),
# because the import's line puts a comma there: "non-air blocks 792923, states 600". The
# guard has to read the line the same way, or it tests a stricter parser than the one that
# runs and fails a line the device test would have accepted.
B2="${B2%,}"
case "$C2" in ''|*[!0-9]*) fail "the import's line lost its chunk count" ;; esac
[ "${B2:-0}" = 792923 ] || fail "the import's line lost its block count (got '${B2:-absent}')"

echo "open-line: both shapes parse ($W_CHUNKS chunks / $W_BLOCKS blocks / $W_ERRORS errors)"
