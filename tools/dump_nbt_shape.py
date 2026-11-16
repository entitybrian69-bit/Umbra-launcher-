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


def entry_shape(entry):
    """What a palette entry looks like: its tag type, or a compound's key names."""
    if isinstance(entry, str):
        return f"string len {len(entry)}"
    if isinstance(entry, list) and entry and isinstance(entry[0], tuple):
        return "compound keys " + ",".join(k for k, _ in entry)
    if isinstance(entry, list):
        return f"list of {len(entry)}"
    if isinstance(entry, int):
        return "int"
    return type(entry).__name__


def describe_shapes(path):
    """One line per section of the first chunk: what it holds and how it is written."""
    for nbt in world_oracle.file_chunks(path):
        root = world_oracle.parse(nbt)
        body = world_oracle.get(root, "Level") or root
        sections = world_oracle.get(body, "sections") or []
        print(f"  chunk root keys: {','.join(k for k, _ in root)}")
        print(f"  sections: {len(sections)}")
        for index, sec in enumerate(sections):
            keys = ",".join(k for k, _ in sec) if isinstance(sec, list) else type(sec).__name__
            bs = world_oracle.get(sec, "block_states")
            if bs is None:
                print(f"  section[{index}] Y={world_oracle.get(sec, 'Y')} keys {keys}: no block_states")
                continue
            palette = world_oracle.get(bs, "palette")
            data = world_oracle.get(bs, "data")
            n_pal = len(palette) if palette is not None else "none"
            n_data = len(data) if data is not None else "none"
            first = entry_shape(palette[0]) if palette else "empty"
            print(f"  section[{index}] Y={world_oracle.get(sec, 'Y')} keys {keys}: "
                  f"palette {n_pal} data {n_data} first entry {first}")
        return


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    path = argv[1]
    slots = list(chunks_of(path))
    print(f"{len(slots)} chunks in {path}")
    if not slots:
        return 1
    try:
        describe_shapes(path)
    except (ValueError, struct.error) as exc:
        print(f"  the parser refused the first chunk: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
