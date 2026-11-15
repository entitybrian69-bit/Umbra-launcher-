# Decisions and their reasons

Newest first. Each entry says what was decided, why, and what it costs.

## D-020 The GPU self-test draws into its own framebuffer and reads RGBA

Three device-only facts shaped this. First, the window's back buffer has no
defined contents after a swap, so the self-test renders into an offscreen
RGBA8 framebuffer with a depth renderbuffer and reads that. Second, the emulator
refuses `glReadPixels(..., GL_RGB, ...)` with `GL_INVALID_OPERATION` (0x502),
which silently left the readback buffer as zeros and failed every pixel; the read
is RGBA. Third, a texture still bound while it is attached to the framebuffer
being drawn into is a feedback loop, and SwiftShader discarded those draws — the
texture is unbound after the attachment. The self-test also runs at a defined
point in the frame (a flag set by the touch handler) instead of in the middle of
event dispatch.

Cost: an 8 MB 1920x1080 RGBA8 target, allocated on first use, and one full-screen
pixel comparison per tap (2,073,600 calls into Goose).

## D-019 The screenshot reference is a real capture, chosen by looking at it

`docs/reference/emulator_home.png` is run 43670787000's own screenshot, committed
by hand after viewing it, not by the job that produced it. The gate then compares
each new capture against it (16x16 signature, mean absolute difference <= 24) and
also requires the two captures of a run to differ, so a stale file cannot pass.
Cost: when the home screen legitimately changes, a human must look at the new
capture and commit it; the gate is a regression detector, not an oracle.

## D-022 JSON is parsed strictly, by our own reader

The model data in the jar is JSON, so the core needs a JSON reader
(`goose/core/json.goose`, 302 checks). It is strict: trailing commas, unquoted
names, raw control characters in strings, unknown escapes, leading zeroes,
lone surrogates and trailing bytes are all errors with a byte offset, and nesting
past 48 levels is refused rather than overflowing the stack. Rationale: a model
file the game would reject must not be half-accepted here, because the failure
then shows up as wrong geometry far from its cause. Numbers are parsed by hand
(sign, fraction, exponent) so no locale-dependent `strtod` sits in the path.
Cost: about 480 lines of Goose, and no support for JSON5-style leniency.

## D-021 CI runs Windows binaries on Windows

Gate 5 needs a Windows build that is actually executed. `pc.yml` builds the
Windows x64 binary inside MSYS2 UCRT64 on `windows-latest` and runs it there
(MINGW64 was the first choice; MSYS2 deprecated it in favour of UCRT64). The
alternative — cross-compiling with mingw-w64 on Linux and running under Wine —
would prove the binary formats but not that it starts on Windows. Cost: the
Windows job takes ~6 minutes and installs a toolchain each run; publishing its
evidence must happen in Git Bash rather than MSYS2, because the checkout's git
credentials belong to the Windows git that Git Bash uses.

## D-018 The home screen is a fixed view, so the screenshot gate compares like with like

The first device screenshots showed the scene drifting: the camera orbited with
frame time, so two captures taken seconds apart differed in every pixel and no
reference could gate anything. The demo view is now a fixed three-quarter view,
with the camera distance and the near/far planes derived from the mesh's own
extent and aimed at the top of the world (the demo world is filled from y = -64,
so its centre is inside solid stone). The vertex colour is no longer multiplied
by ambient occlusion twice — Goose already bakes face shade and AO into it, and
the double multiply is why the first device screenshots showed a black world.
Cost: no motion on the home screen until the real world renderer arrives.

## D-017 The app blocks when it has no window, and rebuilds after a context loss

The first version of the frame loop polled with a zero timeout whatever the
window state, which burns a whole core while a game is paused, and it kept GL
objects across an EGL context loss (pause/resume), which is undefined. The loop
now passes -1 to `ALooper_pollOnce` while there is no window and rebuilds the app
via `umbra_app_shutdown()`/`umbra_app_init()` when a window returns after an
`APP_CMD_TERM_WINDOW`. Cost: a pause costs one resume-time rebuild (a few ms of
world meshing) instead of trusting stale GL names.

## D-016 CI's evidence channel is annotations plus files committed by the job

The environment that drives this project cannot download GitHub job logs
(`gh run view --log` returns empty) or artifacts (the redirect to
`productionresultssa*.blob.core.windows.net` is unreachable). Rather than
declare "CI-only, unknown", the workflow funnels what it learned through two
readable channels: `::notice`/`::error` annotations (capped at 10 per level per
step, so only milestones go there) and `evidence/ci/`, which the emulator job
commits back to the branch with `[skip ci]` — screenshots, logcat, dumpsys and a
`summary.txt` written as the test proceeds. Cost: CI commits land on the working
branch, so local work is rebased onto them; `evidence/ci/` keeps only the last
400 KB of logcat.

## D-015 The toolchain comes from the runner image, not from pinned numbers

The APK build runs on whatever NDK, CMake and JDK the Ubuntu runner ships, with
two exceptions that are pinned for a stated reason: the JDK is 21 (the image's
default JDK 25 produces class-file version 69, which Gradle 8.11 and AGP 8.7
refuse) and the Gradle version is 8.11.1. The NDK version is read from the
installed NDK and handed to Gradle through `UMBRA_NDK_VERSION`, so `build.gradle`
never names a version the machine might not have. Cost: the build is only as
reproducible as the runner image; the log's toolchain step records what was
actually used per run.

## D-014 The release keystore is in the repository on purpose

`ci/umbra-release.p12` is a self-signed RSA-2048 key (CN=Umbra release, valid
2026-11-14 to 2056-11-06, password `umbra-release`, alias `umbra`) committed with
the build, so every build is signed by the same key and an installed Umbra can be
upgraded in place. This protects nothing: the key is public, so anyone can sign
an APK that Android will accept as an update to Umbra. It exists to make builds
consistent, not to authenticate them. A real distribution needs a private key
outside the repository; that is recorded in `KNOWN_ISSUES.md` as a security
limitation. Nothing but our own code is redistributed (see D-001).

## D-013 The emulator test is a script with hard timeouts, not an action

`tools/emulator_smoke.sh` creates the AVD, boots the emulator, installs, launches,
taps the self-test, captures two screenshots, soaks the process and writes
`summary.txt`. Every device call goes through `timeout`, because the first two
attempts with `reactivecircus/android-emulator-runner` failed inside the action
with an unreadable log (87 s, then 17+ minutes with no output), and a hang is
indistinguishable from a failure when the log cannot be read. Cost: the script
owns emulator details (system image, AVD home, boot polling) that an action would
otherwise hide.

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
