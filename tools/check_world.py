#!/usr/bin/env python3
"""Compare the two readings of a world: the Goose loader and the Python oracle.

The Goose side is the code the renderer uses; the Python side is a second
implementation of the same format. A block "matches" when both readers put the same
state at the same position, which is exactly what agreeing on a chunk's hash means: the
hash covers every non-air block of that chunk, in a fixed order.

Reports a match rate, not a boolean, because "129 of 441 chunks" is information and
"FAIL" is not.

usage: tools/check_world.py <goose dump> <oracle dump>
"""
import sys

REQUIRED = 1.0   # every block in every chunk has to agree


def read(path):
    chunks = {}
    blocks = {}
    total = None
    details = []
    bad = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                if line.startswith("chunk "):
                    parts = line.split()
                    # chunk <cx> <cz> blocks <n> hash <h>
                    chunks[(int(parts[1]), int(parts[2]))] = (int(parts[4]), int(parts[6]))
                elif line.startswith("block "):
                    parts = line.split()
                    blocks[parts[1]] = int(parts[2])
                elif line.startswith("total "):
                    parts = line.split()
                    total = (int(parts[1]), int(parts[2]), int(parts[3]))
                elif line.startswith("detail "):
                    details.append(line)
            except (IndexError, ValueError):
                # A line this cannot read is information, not a traceback: the first real
                # save produced `block` with an empty name and the comparison died instead
                # of saying so.
                bad.append(line)
    if bad:
        print(f"{path}: {len(bad)} line(s) this comparison cannot read, first: {bad[0]!r}")
    return chunks, blocks, total, details


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    a, b = sys.argv[1], sys.argv[2]
    ca, ba, ta, da = read(a)
    cb, bb, tb, db = read(b)
    print(f"{a}: {len(ca)} chunks, {ta[1] if ta else 0} blocks, {len(ba)} states")
    print(f"{b}: {len(cb)} chunks, {tb[1] if tb else 0} blocks, {len(bb)} states")

    if not ca or not cb:
        print("FAIL: one of the two readings is empty")
        return 1

    keys = set(ca) | set(cb)
    matched_chunks = 0
    matched_blocks = 0
    total_blocks = 0
    for k in sorted(keys):
        want = ca.get(k)
        got = cb.get(k)
        count = (want or got)[0]
        total_blocks += count
        if want == got:
            matched_chunks += 1
            matched_blocks += count
    chunk_rate = matched_chunks / len(keys)
    block_rate = matched_blocks / total_blocks if total_blocks else 0.0
    print(f"chunks that agree: {matched_chunks} of {len(keys)} ({chunk_rate * 100:.2f}%)")
    print(f"blocks in agreeing chunks: {matched_blocks} of {total_blocks} "
          f"({block_rate * 100:.2f}% of every non-air block in the save)")

    # The states, and the block-by-block detail for the chunks both sides dumped.
    state_diff = {k for k in set(ba) | set(bb) if ba.get(k) != bb.get(k)}
    print(f"block states that agree: {len(set(ba) | set(bb)) - len(state_diff)} of "
          f"{len(set(ba) | set(bb))}")
    detail_rate = 1.0
    if da or db:
        same = sum(1 for x, y in zip(da, db) if x == y)
        detail_rate = same / max(len(da), len(db))
        print(f"detail records that agree: {same} of {max(len(da), len(db))} "
              f"({detail_rate * 100:.2f}%), block by block")

    for k in sorted(keys):
        if ca.get(k) != cb.get(k):
            print(f"  first disagreement: chunk {k} goose {ca.get(k)} oracle {cb.get(k)}")
            break
    for k in sorted(state_diff)[:5]:
        print(f"  state count differs: {k} goose {ba.get(k)} oracle {bb.get(k)}")

    if chunk_rate < REQUIRED or len(state_diff) > 0 or detail_rate < REQUIRED:
        print("FAIL: the two readings of the world do not agree")
        return 1
    print(f"PASS: two independent readers agree on every block of all {len(keys)} chunks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
