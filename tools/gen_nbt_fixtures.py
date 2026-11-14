#!/usr/bin/env python3
"""An independent NBT writer (the format as minecraft.wiki documents it) used
to produce fixtures for the Goose reader, plus the canonical dumps the reader's
values are compared against."""
import json, os, struct

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "goose", "test", "fixtures", "nbt"))

def s(text):
    b = text.encode()
    return struct.pack(">H", len(b)) + b

def tag(tid, name, payload):
    return bytes([tid]) + s(name) + payload

def byte(name, v): return tag(1, name, struct.pack(">b", v))
def short(name, v): return tag(2, name, struct.pack(">h", v))
def int_(name, v): return tag(3, name, struct.pack(">i", v))
def long_(name, v): return tag(4, name, struct.pack(">q", v))
def float_(name, v): return tag(5, name, struct.pack(">f", v))
def double_(name, v): return tag(6, name, struct.pack(">d", v))
def byte_array(name, data): return tag(7, name, struct.pack(">i", len(data)) + bytes(data))
def string(name, v): return tag(8, name, s(v))
def list_(name, elem, items): return tag(9, name, bytes([elem]) + struct.pack(">i", len(items)) + b"".join(items))
def compound(name, children): return tag(10, name, b"".join(children) + b"\x00")
def int_array(name, vals): return tag(11, name, struct.pack(">i", len(vals)) + b"".join(struct.pack(">i", v) for v in vals))
def long_array(name, vals): return tag(12, name, struct.pack(">i", len(vals)) + b"".join(struct.pack(">q", v) for v in vals))

def root(name, children):
    return b"\x0a" + s(name) + b"".join(children) + b"\x00"

def level_dat():
    """A level.dat with the shape and tag types the game uses. Values are ours;
    the format is the game's."""
    root_children = [
        compound("Data", [
            compound("Version", [int_("Id", 3955), string("Name", "26.3"), int_("Snapshot", 0)]),
            compound("DataVersion", []),  # placeholder replaced below
            string("LevelName", "Umbra test world"),
            int_("version", 19133),
            long_("LastPlayed", 1763200000123),
            byte("initialized", 1),
            byte("allowCommands", 0),
            int_("GameType", 0),
            byte("hardcore", 0),
            int_("Difficulty", 2),
            byte("DifficultyLocked", 0),
            int_("SpawnX", 16), int_("SpawnY", 72), int_("SpawnZ", -32),
            double_("BorderCenterX", 0.0), double_("BorderCenterZ", 0.0),
            double_("BorderSize", 59999968.0), double_("BorderDamagePerBlock", 0.2),
            double_("BorderWarningBlocks", 5.0),
            int_("clearWeatherTime", 0),
            byte("raining", 0), byte("thundering", 0),
            int_("rainTime", 12345), int_("thunderTime", 54321),
            int_("Time", 6000), long_("DayTime", 6001),
            int_("WanderingTraderSpawnChance", 25), int_("WanderingTraderSpawnDelay", 0),
            compound("WorldGenSettings", [
                long_("seed", 4242424242),
                byte("generate_features", 1),
                byte("bonus_chest", 0),
                compound("dimensions", [
                    compound("minecraft:overworld", [
                        compound("generator", [
                            string("type", "minecraft:noise"),
                            compound("biome_source", [
                                string("type", "minecraft:multi_noise"),
                                string("preset", "minecraft:overworld"),
                            ]),
                            long_("seed", 4242424242),
                            compound("settings", [string("preset", "minecraft:overworld")]),
                        ]),
                        byte("type", 0),
                    ]),
                ]),
            ]),
            list_("ServerBrands", 8, [s("vanilla")]),
            long_array("HeightmapsProbe", [1, -2, 3, -4]),
            int_array("SpawnProbe", [10, 20, 30]),
            byte_array("TestBytes", [1, 2, 3, 250]),
            list_("TestInts", 3, [struct.pack(">i", v) for v in (7, -8, 9)]),
            compound("EmptyCompound", []),
            list_("EmptyList", 0, []),
            float_("TestFloat", 1.5),
            double_("TestDouble", -2.25),
            short("TestShort", -300),
            long_("TestLong", -9007199254740993),
        ])
    ]
    # Replace the DataVersion placeholder with the real one.
    data = root("", root_children)
    data = data.replace(tag(10, "DataVersion", b"\x00"), int_("DataVersion", 3955))
    return data

def canonical_dump(path_bytes):
    """A line-per-node dump, produced by parsing the same file with this
    writer's own reader, so the Goose reader's values are compared to an
    independent parse rather than to itself."""
    nodes = []

    def parse(buf, pos, tid, name):
        if tid == 1:
            v = struct.unpack_from(">b", buf, pos)[0]; pos += 1
            val = str(v)
        elif tid == 2:
            v = struct.unpack_from(">h", buf, pos)[0]; pos += 2
            val = str(v)
        elif tid == 3:
            v = struct.unpack_from(">i", buf, pos)[0]; pos += 4
            val = str(v)
        elif tid == 4:
            v = struct.unpack_from(">q", buf, pos)[0]; pos += 8
            val = str(v)
        elif tid == 5:
            v = struct.unpack_from(">f", buf, pos)[0]; pos += 4
            val = repr(v)
        elif tid == 6:
            v = struct.unpack_from(">d", buf, pos)[0]; pos += 8
            val = repr(v)
        elif tid == 7:
            n = struct.unpack_from(">i", buf, pos)[0]; pos += 4
            val = ",".join(str(x) for x in buf[pos:pos + n]); pos += n
        elif tid == 8:
            n = struct.unpack_from(">H", buf, pos)[0]; pos += 2
            val = buf[pos:pos + n].decode(); pos += n
        elif tid == 9:
            elem = buf[pos]; n = struct.unpack_from(">i", buf, pos + 1)[0]; pos += 5
            nodes.append(f"{name} list<{elem}>[{n}]")
            for _ in range(n):
                pos, _ = parse(buf, pos, elem, "")
            return pos, val if False else (pos, None)
        elif tid == 10:
            children = []
            while buf[pos] != 0:
                t = buf[pos]; pos += 1
                n = struct.unpack_from(">H", buf, pos)[0]; pos += 2
                cname = buf[pos:pos + n].decode(); pos += n
                pos, cval = parse(buf, pos, t, cname)
                if cval is not None:
                    children.append(f"/{cname}={t}:{cval}")
                else:
                    children.append(f"/{cname}")
            pos += 1
            nodes.append(f"{name} compound({len(children)})")
            for c in children:
                nodes.append(f"  {c}")
            return pos, None
        elif tid == 11:
            n = struct.unpack_from(">i", buf, pos)[0]; pos += 4
            val = ",".join(str(v) for v in struct.unpack_from(f">{n}i", buf, pos)); pos += 4 * n
        elif tid == 12:
            n = struct.unpack_from(">i", buf, pos)[0]; pos += 4
            val = ",".join(str(v) for v in struct.unpack_from(f">{n}q", buf, pos)); pos += 8 * n
        else:
            raise ValueError(tid)
        nodes.append(f"{name} {tid}:{val}")
        return pos, val

    tid = path_bytes[0]
    n = struct.unpack_from(">H", path_bytes, 1)[0]
    name = path_bytes[3:3 + n].decode()
    parse(path_bytes, 3 + n, tid, name)
    return nodes

def main():
    os.makedirs(BASE, exist_ok=True)
    dat = level_dat()
    with open(os.path.join(BASE, "level.dat"), "wb") as f:
        f.write(dat)
    dump = canonical_dump(dat)
    with open(os.path.join(BASE, "level.dat.dump"), "w") as f:
        f.write("\n".join(dump) + "\n")
    # Broken inputs the reader must refuse.
    broken = {
        "bad_root_tag": b"\x03\x00\x00" + dat[4:],
        "truncated": dat[: len(dat) // 2],
        "empty": b"",
        "unknown_tag": dat[: dat.find(b"\x07")] + b"\x0d" + dat[dat.find(b"\x07") + 1:],
    }
    for name, data in broken.items():
        with open(os.path.join(BASE, f"bad_{name}.dat"), "wb") as f:
            f.write(data)
    print(f"nbt: level.dat {len(dat)} bytes, {len(dump)} dump lines, {len(broken)} broken")

if __name__ == "__main__":
    main()
