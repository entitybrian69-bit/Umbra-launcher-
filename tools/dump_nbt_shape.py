#!/usr/bin/env python3
"""Print the *shape* of one chunk in a region file: keys, types, list lengths.

usage: tools/dump_nbt_shape.py <file.mca> [chunk index]

The two readers read a real save from the real server for the first time and disagreed
with it: the Goose reader found 529 chunks and 0 blocks, and the Python oracle raised
`not enough values to unpack`. Guessing at the format is how a reader "works" on a
synthetic world and reads nothing real, so this prints what the file actually contains -
key names, tag types and list lengths, never block payloads - and that dump goes into the
evidence directory. It reuses the oracle's NBT parser on purpose: if the parser itself is
what fails, the failure is the finding.
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import world_oracle  # noqa: E402  (the same parser the oracle uses)

TYPE_NAMES = {
    1: "byte", 2: "short", 3: "int", 4: "long", 5: "float", 6: "double",
    7: "byte[]", 8: "string", 9: "list", 10: "compound", 11: "int[]", 12: "long[]",
}


def value_of(node):
    return node


def describe(value, indent, depth):
    pad = "  " * indent
    if isinstance(value, list):
        # A list of pairs is a compound in this parser; a plain list is a list.
        if value and isinstance(value[0], tuple) and len(value[0]) == 2:
            print(f"{pad}compound with {len(value)} keys")
            if depth <= 0:
                return
            for key, inner in value:
                print(f"{pad}  {key}: ", end="")
                if isinstance(inner, list) and inner and isinstance(inner[0], tuple):
                    print("compound")
                    describe(inner, indent + 2, depth - 1)
                else:
                    print(type_name(inner), length_of(inner))
        else:
            print(f"{pad}list of {len(value)} {type_name(value[0]) if value else 'nothing'}")
            if value and depth > 0 and isinstance(value[0], list):
                describe(value[0], indent + 1, depth - 1)
    else:
        print(f"{pad}{type_name(value)} {value if isinstance(value, str) else ''}".rstrip())


def type_name(value):
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "compound" if value and isinstance(value[0], tuple) else "list"
    if isinstance(value, int):
        return "number"
    return type(value).__name__


def length_of(value):
    if isinstance(value, list):
        if value and isinstance(value[0], tuple):
            return "compound"
        return f"len {len(value)}"
    if isinstance(value, str):
        return f"len {len(value)}"
    return ""


def chunks_of(path):
    """Yield (index, raw nbt bytes or None) for every chunk slot in a region file."""
    with open(path, "rb") as f:
        header = f.read(8192)
    for slot in range(1024):
        off = struct.unpack(">I", b"\x00" + header[slot * 4:slot * 4 + 3])[0]
        if off == 0:
            continue
        yield slot, off


def read_chunk(path, offset):
    with open(path, "rb") as f:
        f.seek(offset * 4096)
        length = struct.unpack(">i", f.read(4))[0]
        _compression = struct.unpack(">B", f.read(1))[0]
        raw = f.read(length - 1)
    return zlib.decompress(raw)


TAG_NAMES = {
    1: "byte", 2: "short", 3: "int", 4: "long", 5: "float", 6: "double",
    7: "byte[]", 8: "string", 9: "list", 10: "compound", 11: "int[]", 12: "long[]",
}


def kind_of(value):
    if isinstance(value, str):
        return "string"
    if isinstance(value, list) and value and isinstance(value[0], tuple):
        return "compound"
    if isinstance(value, list):
        return "list"
    if isinstance(value, int):
        return "int"
    return type(value).__name__


def entry_shape(entry):
    """What a palette entry looks like: its tag type, or a compound's keys and their types."""
    if isinstance(entry, str):
        return f"string len {len(entry)}"
    if isinstance(entry, list) and entry and isinstance(entry[0], tuple):
        return "compound {" + ", ".join(f"{k}: {kind_of(v)}" for k, v in entry) + "}"
    if isinstance(entry, list):
        return f"list of {len(entry)}"
    if isinstance(entry, int):
        return "int"
    return type(entry).__name__


def describe_shapes(path):
    """A histogram of how every section in the file is written, plus the odd ones.

    The first version printed section[0] of the first chunk, which on a real save is an
    empty chunk: 24 sections of air, palette 1, string entries, and nothing about the 50
    sections that read as a state with no name."""
    hist = {}
    odd = []
    chunks = 0
    for nbt in world_oracle.file_chunks(path):
        chunks += 1
        root = world_oracle.parse(nbt)
        body = world_oracle.get(root, "Level") or root
        cx, cz = world_oracle.get(root, "xPos"), world_oracle.get(root, "zPos")
        for sec in world_oracle.get(body, "sections") or []:
            y = world_oracle.get(sec, "Y")
            bs = world_oracle.get(sec, "block_states")
            if bs is None:
                key = "no block_states"
                hist[key] = hist.get(key, 0) + 1
                odd.append((cx, cz, y, key))
                continue
            palette = world_oracle.get(bs, "palette")
            data = world_oracle.get(bs, "data")
            if palette and len(palette) == 1 and palette[0] == "minecraft:air":
                key = "one entry, all air"
                hist[key] = hist.get(key, 0) + 1
                continue
            form = entry_shape(palette[0]) if palette else "palette missing"
            n_pal = len(palette) if palette else 0
            if n_pal <= 1:
                bucket = "1"
            elif n_pal <= 4:
                bucket = "2-4"
            elif n_pal <= 16:
                bucket = "5-16 (4 bits)"
            elif n_pal <= 32:
                bucket = "17-32 (5 bits)"
            elif n_pal <= 64:
                bucket = "33-64 (6 bits)"
            elif n_pal <= 128:
                bucket = "65-128 (7 bits)"
            elif n_pal <= 256:
                bucket = "129-256 (8 bits)"
            else:
                bucket = ">256 (direct?)"
            key = (f"{form}, palette {bucket}, "
                   f"data {'none' if data is None else 'present'}")
            hist[key] = hist.get(key, 0) + 1
            known = form.startswith("compound {Name:") or form.startswith("string len") or form == "int"
            if not known:
                entries = ", ".join(entry_shape(e) for e in (palette or [])[:4])
                odd.append((cx, cz, y, f"{key}; first entries: {entries}"))
    print(f"  {chunks} chunks read")
    for key in sorted(hist, key=lambda k: -hist[k]):
        print(f"  {hist[key]:6d} sections: {key}")
    if odd:
        print(f"  {len(odd)} section(s) in a form the readers do not know:")
        for cx, cz, y, what in odd[:8]:
            print(f"    chunk {cx},{cz} Y={y}: {what}")
    return


# --- raw bytes, for when a shape is not enough ---------------------------------
# A tiny NBT walker that keeps byte offsets, so the one palette entry the readers cannot
# read can be printed as hex. Independent of the oracle's parser on purpose: if that
# parser is what is wrong, this must not share the mistake.

def walk(data, pos, tag):
    """(value, end position, children offsets) for one payload."""
    start = pos
    if tag == 1:
        return data[pos], pos + 1, None
    if tag == 2:
        return struct.unpack(">h", data[pos:pos + 2])[0], pos + 2, None
    if tag == 3:
        return struct.unpack(">i", data[pos:pos + 4])[0], pos + 4, None
    if tag == 4:
        return struct.unpack(">q", data[pos:pos + 8])[0], pos + 8, None
    if tag == 5:
        return struct.unpack(">f", data[pos:pos + 4])[0], pos + 4, None
    if tag == 6:
        return struct.unpack(">d", data[pos:pos + 8])[0], pos + 8, None
    if tag == 7:
        n = struct.unpack(">i", data[pos:pos + 4])[0]
        return data[pos + 4:pos + 4 + n], pos + 4 + n, None
    if tag == 8:
        n = struct.unpack(">H", data[pos:pos + 2])[0]
        return data[pos + 2:pos + 2 + n].decode("utf-8", "replace")[:40], pos + 2 + n, None
    if tag == 9:
        sub = data[pos]
        n = struct.unpack(">i", data[pos + 1:pos + 5])[0]
        pos += 5
        items = []
        for _ in range(n):
            value, pos, kids = walk(data, pos, sub)
            items.append((value, kids))
        return items, pos, None
    if tag == 10:
        members = []
        while True:
            t = data[pos]
            if t == 0:
                return members, pos + 1, None
            n = struct.unpack(">H", data[pos + 1:pos + 3])[0]
            name = data[pos + 3:pos + 3 + n].decode("utf-8", "replace")
            members.append((name, t, pos + 3 + n))
            _value, pos, _kids = walk(data, pos + 3 + n, t)
    if tag == 11:
        n = struct.unpack(">i", data[pos:pos + 4])[0]
        return list(struct.unpack(">%di" % n, data[pos + 4:pos + 4 + 4 * n])), pos + 4 + 4 * n, None
    if tag == 12:
        n = struct.unpack(">i", data[pos:pos + 4])[0]
        return list(struct.unpack(">%dq" % n, data[pos + 4:pos + 4 + 8 * n])), pos + 4 + 8 * n, None
    raise ValueError(f"tag {tag} at {pos}")


def hexdump(data, pos, count=96):
    chunk = data[pos:pos + count]
    for i in range(0, len(chunk), 16):
        row = chunk[i:i + 16]
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"    {pos + i:6d}  {' '.join(f'{b:02x}' for b in row):<47}  {text}")


def entry_members(nbt, pos, tag):
    """(member names, end position) of a compound payload, or ([], end) otherwise."""
    if tag != 10:
        value, end, _kids = walk(nbt, pos, tag)
        return [], end
    value, end, _kids = walk(nbt, pos, 10)
    return [name for name, _t, _at in value], end


def describe_bytes(files, limit=3):
    """Print the palettes the readers cannot read, as member names and raw bytes.

    It looks for a palette whose first entry is a compound without a `Name` member - the
    form that came back as 'compound {: string}' - and prints up to `limit` of them with
    their bytes, then falls back to the first palettes with compounds in them.
    """
    printed = 0
    fallback = []
    for path in files:
        for nbt in world_oracle.file_chunks(path):
            try:
                root, _end, _kids = walk(nbt, 3, 10)
            except (ValueError, struct.error):
                continue
            sections_at = None
            for name, tag, at in root:
                if name == "sections" and tag == 9:
                    sections_at = at
                    break
            if sections_at is None:
                continue
            sub_tag = nbt[sections_at]
            count = struct.unpack(">i", nbt[sections_at + 1:sections_at + 5])[0]
            pos = sections_at + 5
            for index in range(count):
                sec, pos, _k = walk(nbt, pos, sub_tag)
                if not sec:
                    continue
                for name, tag, at in sec:
                    if name != "block_states" or tag != 10:
                        continue
                    for inner, itag, iat in walk(nbt, at, 10)[0]:
                        if inner != "palette" or itag != 9:
                            continue
                        element_tag = nbt[iat]
                        n = struct.unpack(">i", nbt[iat + 1:iat + 5])[0]
                        if n < 2 or element_tag != 10:
                            continue
                        names, _e = entry_members(nbt, iat + 5, element_tag)
                        record = (path, index, n, names, iat + 5)
                        if "Name" not in names:
                            print(f"  {path}: section[{index}] palette of {n}, "
                                  f"element tag {element_tag}, first entry members {names}")
                            hexdump(nbt, iat + 5, 96)
                            printed += 1
                            if printed >= limit:
                                return
                        elif len(fallback) < limit:
                            fallback.append(record)
    if printed == 0:
        for path, index, n, names, at in fallback:
            print(f"  fallback: {path}: section[{index}] palette of {n}, first entry members {names}")
            hexdump(nbt, at, 64)
    if printed == 0 and not fallback:
        print("  (no compound palette with two or more entries was found)")


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    paths = [a for a in argv[1:] if not a.startswith("--")]
    want_hex = "--hex" in argv
    if len(paths) == 0:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    for path in paths:
        print(f"== {path}")
        if want_hex:
            try:
                describe_bytes(paths)
            except (ValueError, struct.error) as exc:
                print(f"  could not walk it: {exc}")
            return 0
        try:
            describe_shapes(path)
        except (ValueError, struct.error) as exc:
            print(f"  the parser refused a chunk: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
