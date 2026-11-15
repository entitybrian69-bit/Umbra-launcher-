# Decisions and their reasons

Newest first. Each entry says what was decided, why, and what it costs.

## D-032 The release verifier is a script, because the inline version lied

The first real release run (`43691770806`) created the pre-release, then its
verification step wrote a report containing only a header and exited 1: no asset
lines, no result line, and no clue. The cause was one line -- `cut -d' ' -f2-` on
`sha256sum` output, which begins "hash  name" with two spaces, so every download
URL had a leading space and every `curl` returned `000`. A hash check that never
downloads anything looked exactly like a broken release.

So the check moved into `tools/verify_release.sh`, which can be run, and is run,
outside CI: pointed at a local `python3 -m http.server`, it reports `RESULT: PASS -
2 assets re-downloaded ... and every sha256 matched`, and after one byte was
appended to a served file it reports `result: MISMATCH` for that asset and
`exit=1`. Each asset is retried five times, because a release can take a few
seconds to become downloadable, and the downloaded files are kept under
`dist/downloaded/` so the next step can execute them rather than trust them.

## D-031 A frame is only drawn into a surface that is at least 16 pixels wide

Run `43687356640` shipped a blank screenshot: `EGL up: 1x1 ... hud: button 0 at
25,-269 size -49x63 on 1x1`. The EGL surface had been created before the window
had buffers, `eglQuerySurface` said 1x1, no resize event ever followed, and the
app faithfully cleared and drew into a one-pixel viewport for the whole run. The
screenshot gate caught it as a blank screen; nothing said why.

Three changes, each cheap and each about not trusting a single event:

* `android_main` re-reads the surface size **every frame** with
  `eglQuerySurface` and re-reads the insets when it changed. A size that arrives
  in no lifecycle callback cannot go stale.
* `umbra_app_frame` returns without drawing when the surface is under 16 px, so a
  stub surface produces no frame instead of a wrong one, and `hud_button_rect`
  returns an empty rectangle instead of a negative one.
* the HUD layout is logged from the frame loop, once a real size is known, instead
  of from `umbra_app_init` where the surface may still be a stub. The emulator
  smoke test now has a `display-size` phase that fails the run if the app drew
  into a surface narrower than 320 px.

Also in this entry, because the same screenshot exposed it: `hud_rect()` sampled
UV (0,0) of the glyph atlas -- the first pixel of the space glyph, which is
transparent -- so every panel and button background was invisible and the text
floated in the sky. Flat rectangles now sample a reserved opaque texel at the
atlas's bottom-right corner.

Cost: one `eglQuerySurface` pair per frame (microseconds) and one 8-bit texel of
the font atlas.

## D-030 The HUD is laid out in display pixels, scaled by the display density

The first 0.3.0 emulator screenshot showed why this could not wait: the overlay was
drawn at scale 1, which on a 420 dpi screen (density 2.62) makes a capital letter
three density-independent pixels tall, and the three buttons ran the full width of
the display into a 126 px navigation-bar strip. Both are the kind of thing that
looks fine in a 1568 px screenshot and is unusable on a phone.

So: `hud_scale()` returns `dpi_scale * 1.2`, clamped to 1..5; the row height, the
margins, the button height and the button labels all derive from it, and
`hud_button_rect()` -- the one function both the drawing code and the touch test
ask -- subtracts the **right** inset as well as the left one. The backdrop's height
is computed from the rows it will contain rather than being a constant, because
the benchmark block is four lines.

Cost: on the emulator the overlay now covers about a third of the height instead
of a fifth. That is a deliberate trade for text a person can read.

## D-029 A release is proven by downloading it again, and a tag builds its own assets

Three choices, all made because this project can only see GitHub through a narrow
door (job logs and artifact downloads are unreadable here, D-016):

* **The publishing job is not the verifying job.** `release.yml` builds the APK and
  both PC binaries from the tag, creates the pre-release, and then a separate step
  downloads **every** asset from its public release URL, requires HTTP 200, and
  compares the SHA-256 with the one just built. The result is committed as
  `RELEASE_VERIFY.txt` with the run URL. A release whose bytes were never fetched
  back is not evidence of anything.
* **The Windows asset is executed, under wine.** The `pc` workflow already runs the
  `.exe` natively on a Windows runner; the release job runs the *shipped* file
  under wine as well, so the released artifact is one that ran. Cross-compiling and
  hoping is what this project keeps refusing to do.
* **An existing release is added to, never replaced.** If the tag already has a
  release, the job uploads with `--clobber` on individual assets rather than
  deleting and recreating it, and `--prerelease` is always set while the parity table
  is empty.

Cost: the job needs `permissions: contents: write` and pushes a commit, and wine
adds ~300 MB to the release job image. Accepted: the alternative is publishing
numbers nobody checked.

A related fix came out of run `43684262551`: the emulator job's "commit the
evidence" step failed with a rejected push, because the branch moved while the
emulator ran. All four workflows now call one script, `tools/commit_evidence.sh`,
which merges and retries up to four times and **never rebases** (D-028).

That script then caught a worse bug in itself: run `43685520182` reported its
"commit the evidence" step as **success** while committing nothing, because the
`git add` line had been lost when the step was rewritten. A step that commits
nothing looks exactly like a step that worked. Steps that must always produce
evidence now set `REQUIRE_EVIDENCE=1`, and the script fails if nothing is staged.

**Re-taken 2026-11-15** after the overlay was scaled by the display density, given
background panels and kept inside the system insets (D-030, D-031). The previous
reference showed three-pixel-high text and invisible button backgrounds; keeping
it would have meant a gate that passes while the screen is unusable. The capture
is `evidence/ci/shot1.png` from run `43688102045`, copied unmodified.

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

## D-026 What the real jar taught the checker, in one place

Four rules changed after looking at 26.3's own files, each because the first
version of the checker called correct data broken:

- A model is only checked if a blockstate can render it. `block/cube_all.json`
  carries `"all": "#all"` as a slot for a child to fill, and `block/air.json`
  names `block/air`, a texture that does not exist — both are fine precisely
  because nothing draws them (1589 of 4192 models are unused).
- Inverted boxes are legal: `block/cube_all_inner_faces.json` has `from` greater
  than `to` on purpose (16 such boxes in the jar).
- A texture value may be an object — `{"sprite": "minecraft:block/x",
  "force_translucent": true}` — which is how every stained glass model names its
  texture in 26.3.
- A face's `texture` may omit the `#` (`heavy_core` says `"texture": "all"`), and
  every part of a box `rotation` is optional.
- The "whole number of square frames" rule applies to block textures only; GUI,
  entity, painting and panorama sprites are any size.

Decision: the checker keeps strict rules where the client is strict (models that
exist, parents that exist, textures that exist, four UV numbers per face) and
stops inventing rules where the client is lenient. Cost: it can no longer catch a
"physically odd" box, only a malformed one.

## D-025 The game version is pinned to 26.3, and the jar is fetched, never committed

`MC_VERSION=26.3`, the latest release in Mojang's manifest when this was written
(released 2026-09-15, java 25, asset index 34). `tools/fetch_jar.sh` verifies the
version JSON against the manifest's sha1 and the client jar against the sha1 and
size inside that JSON, so a redirected or truncated download fails loudly. The
41 MB jar itself is never committed: `evidence/jar/` holds the pin, the
checksums and the checker's output only. Cost: the jar job needs the network and
about eight minutes; the sandbox that writes the code cannot reach Mojang at all,
so the pin can only be confirmed in CI.

## D-028 A history incident, and what protects the work now

On 2026-11-15 a `git pull --rebase` against a branch that CI also commits to
(evidence commits) left the local branch's ancestry broken: the local head's
parent was the session's base commit rather than the previous work, so every
local commit looked like it re-added the whole tree, and the rebase produced
add/add conflicts on files that had existed for days. Nothing was lost — the
working tree held every change — but the local history was not the sequence it
appeared to be.

The recovery was: keep the working tree, re-commit onto the remote tip
(`git reset --mixed origin/…`, restore the remote's evidence files, commit once).
The state before recovery is preserved on `backup-before-reset`, the old `main`
(`c10bffc`, the repository's initial commit) is preserved on `legacy`, and both
are pushed. Nothing was force-pushed and no branch was deleted.

What changes because of it: CI writing to the same branch that work happens on is
the root cause — an evidence commit landing between a `pull` and a `push` makes a
rebase the default answer, and a rebase is what went wrong. From now on the
branch is pulled only with `git pull --rebase` *after* confirming the working
tree is clean, and the tip is checked against the remote before any push
(`git ls-remote`); releases are tagged from this branch rather than by moving
`main`, so a later recovery can never disturb a published version.

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
