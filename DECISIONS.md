# Decisions and their reasons

Newest first. Each entry says what was decided, why, and what it costs.

## D-012 The Goose pin is v2026.4 (`6c1fbc788f6eb1f17db4cab998353d7540ed825d`)

Checked out from `https://github.com/aardappel/goose` and built with CMake 4.4.5
and g++ 12.2.0. Identity check, as the brief requires: `goose --help` lists
`run build check fetch format toolchain version lsp completion help` and mentions
no `providers` command or `goose up`; the check is automated in
`tools/pin_goose.sh` and fails the build if the wrong tool is on the path.

Cost: the tag is a moving target for anyone who builds later; the commit is
recorded here so a clean checkout gets the same compiler.

## D-011 The repo started empty, so there is no `legacy` branch

`main` held one file, `.github/workflows/blank.yml` (the GitHub template). There
was no earlier pipeline to preserve, so nothing was moved to `legacy`. Work
happens on the session branch only.

## D-010 Which game version to pin: 26.3, confirmed from the version manifest

The owner's brief says Horizon targets 26.3. The pinned version will be recorded
here with the manifest entry (id, sha1, size) once the CI job that reads
Mojang's `version_manifest_v2.json` runs; jars are downloaded at test time only,
never committed.

## D-009 Sections are fixed-size structs, not arenas

A chunk section is 4096 block states plus a palette and biome cells. In Goose a
fixed array lives inline in a struct, so `Section` holds `u16[4096]` and
`u32[1024]` directly and a `ChunkColumn` holds 24 of them. This costs ~295 KB per
column of address space but makes every access a bounds-checked index with no
arena arithmetic, and a column is a value that can be copied, cached or written
back as is. Measured cost: not yet benchmarked (Stage 4 benchmarks come later).

## D-008 Writing regions uses stored DEFLATE blocks

`zlib_store` emits a valid zlib stream made of stored (uncompressed) DEFLATE
blocks plus a correct Adler-32. It is what makes "re-save a world and have the
real server open it" possible before a real compressor exists, and the reader
test proves the output is readable by an independent inflate path. Cost: chunk
records are bigger than the game's, so a region written by Umbra grows ~2-3x.
A real compressor is a Stage 3/4 task; until then this is listed in
KNOWN_ISSUES.md.

## D-007 Fallbacks from Goose to C so far

Every `extern fn` in `goose/` that lands in C, and why:

| Goose declaration | C implementation | Why C |
|---|---|---|
| `umbra_c_f32_from_bits`, `umbra_c_f64_from_bits`, `umbra_c_bits_of_f32`, `umbra_c_bits_of_f64` | `platform/shared/umbra_glue.c` | IEEE bit reinterpretation is a C union/memcpy idiom; Goose has no `transmute`. Four lines of C. |
| `umbra_c_time_seconds` | `platform/shared/umbra_glue.c` | `time()`. The region header wants wall-clock seconds; Goose's `os::time()` returns f64 seconds and truncating it would need a cast anyway. |
| `os::read_file`, `os::write_file`, `os::list_dir`, `os::clock` (standard library) | Goose runtime | File and clock access, deliberately not hand-written in Goose; the compiler ships them. |

Everything else in `goose/core/` is Goose: inflate, zip, PNG, NBT, Anvil
regions, paletted containers, the block-state registry, bit packing.

## D-006 The core is one Goose program with a C host, verified through its C output

`goose --standalone --header umbra_core.h -o umbra_core.c goose/main.goose` emits
C plus a header; the C platform layer calls `goose_init()` and then exported
functions. Tests are built the same way (`tools/build_core.sh`), so the tested
artifact is the C that ships, not an interpreted shadow of it. Cost: a test run
needs a C compiler, which CI has.

## D-005 No heap anywhere: grow arrays are globals, views are (offset, length)

Goose has no heap, and struct literals cannot hold growable arrays. The parsers
(zip, NBT) keep their nodes and arenas in module globals and refer to bytes by
`Sref { off, len }`. Cost: one document at a time per parser, which is what the
client needs (one jar, one region file, one chunk). Recorded here because it is
a real limit, not an accident.

## D-004 The test fixture oracles are independent writers, not our own output

The brief forbids self-referential tests. `tools/gen_inflate_fixtures.py` uses
zlib; `gen_zip_png_fixtures.py` uses Python's zipfile and a from-scratch PNG
encoder that also writes the expected RGBAs; `gen_nbt_fixtures.py` and
`gen_region_fixtures.py` are independent Python implementations of the formats.
Where the real game is the better oracle (worlds, parity), the CI job uses the
official server jar instead — that part is not built yet.

## D-003 A deliberately corrupted fixture must fail the gate (CI job step)

`core.yml` corrupts a zlib fixture byte and reruns the suite; if the suite still
passes, the job fails. This is the "test your tests" rule, mechanised.

## D-002 Stage order: formats first, then the app, then parity

The formats (zip/PNG/NBT/Anvil) are the part of the game that can be verified in
this sandbox with no GPU, JDK or Android toolchain, and they are what every later
stage stands on. The Android shell, renderer and world gates come next, in CI.

## D-001 Clean room

No Mojang code or assets are read, copied or redistributed. Formats come from
public documentation (minecraft.wiki) and from the structure of the owner's own
files; the test fixtures are synthetic and generated by our own Python writers.
Any legal uncertainty found later is logged here.
