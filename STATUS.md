# Status

Updated 2026-11-16 (the world gate is met; the phone can now obtain the game's own
files, and until 0.3.7 it was drawing placeholders). This file is the contract between
sessions: if the work is interrupted, a single "continue" resumes from **Next steps**
with nothing lost.

Everything below was produced by a command whose output is quoted or linked.
Nothing unverified is listed as done.

## Where the project is

Stage 0 (setup) is done. Stage 1 (the file formats the game is made of: zip,
PNG, NBT, Anvil regions, paletted chunk sections) is done and tested. Stage 2
(the Android shell, the GLES3 renderer, the GPU self-test, the benchmark, the PC
headless host) now runs on a device: **the APK builds, passes the integrity gate,
installs on the CI emulator, draws a meshed world, passes its own pixel-exact GPU
self-test and survives a soak**, and the screenshot gate has a committed
reference to compare against.

Both PC binaries are built and executed in CI on their own platforms, with
checksums committed as evidence. The official client jar for **26.3** is now
downloaded in CI (never committed) and its model data is checked against itself:
every model a blockstate can render resolves through its parent chain to
textures that exist in the jar. That is the first half of gate 6 — the second
half, comparing *rendered* worlds with the real client, is not started.

Two pre-releases are published and stay published: `v0.3.0-pre` and
`v0.3.1-pre`, each with its three assets downloaded again and hashed, and each
binary run (`RELEASE_VERIFY.txt`). The owner's phone ran `0.3.1` and returned three
findings - a self-test that failed on 2 458 665 pixels, a previous run that ended
in an ANR, and a benchmark that was showing the display's 60 Hz cap. `0.3.2` fixes
all three, and fixing them exposed four more defects that had already broken a CI
run (see **0.3.2** below). Gate 4 is closed on ARM at the host-suite level. The jar's
own blockstates, models and textures now draw a world (step 3, below), but only on
the host and in CI: the phone still draws the placeholder atlas, there are still no
world-parity numbers, and there is no world loaded from a real save to walk around
in. The Android arm64 `.so` inside the APK has never been executed by CI.
Umbra is not Minecraft, and the parity table is empty.

| Gate | State | Evidence |
|---|---|---|
| 1. CI builds from a clean checkout | PASSING | run `43671700216`: `Build APK (arm64 + x86_64)` job `completed success` |
| 2. APK checks (unzip/aapt2/apksigner/lib per ABI) | PASSING | same run, step `Gate 2 - APK integrity` success; annotations: `package: name='org.umbra.client' versionCode='1' versionName='0.1.0' compileSdkVersion='35'`, `native-code: 'arm64-v8a' 'x86_64'`, `apksigner … v1 scheme: false` (v2/v3 cover minSdk 24) |
| 3. Emulator smoke + fresh screenshot | PASSING (caught a blank screen, then a failing self-test) | run `43671700216`: every step of `Emulator smoke test + screenshot` is `success`, including `Screenshot gate (fresh, non-blank, similar to the reference)`. That run's own capture differs from the reference byte for byte (`evidence/ci/shot1.png` sha256 `26e81928eb09aea9`, reference `ea2a1be5…`) and still measures `mean absolute difference 0.00 (of 255)` |
| 4. Core tests on x86_64 | PASSING | run `43674038711`, step `Core test suite (formats, mesher)`: `PASS mem (19) inflate (97) zip (137) png (153) nbt (196) region (237) json (302) mesh (340)`, `all modules passed` (`evidence/ci/core-tests.txt`) |
| 4. Core tests on arm64 | PASSING (host suite; the Android `.so` is still never executed) | run `43689588892`, job `Goose core tests (arm64)` on `ubuntu-24.04-arm`: `host: aarch64`, `compiler: cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`, then `PASS mem (19) inflate (97) zip (137) png (153) nbt (196) region (237) json (302) mesh (340)`, `all modules passed`, `c-host: goose_exit returned 0` (`evidence/ci/core-tests-arm64.txt`, committed by the job). **This is the host suite built for aarch64 Linux, not the APK's `libumbra.so`** -- that one is NDK clang, bionic, and is compiled by the `android` job and never run |
| 5. PC builds (Windows x64, Linux x64) + headless self-test | PASSING | run `43724314094`, whose jobs `Linux x64 build + headless self-test` and `Windows x64 build + headless self-test` both report `success` on `a717183`: both `PASS: 149 checks, 0 failures`, `evidence/ci/pc-linux-x64.txt` and `pc-windows-x64.txt`. Earlier: run `43674038711`: `Linux x64 build + headless self-test` and `Windows x64 build + headless self-test` both `completed success`; the Windows binary ran under MSYS2 UCRT64 on `windows-latest`, not under Wine. `evidence/ci/pc-linux-x64.txt` and `pc-windows-x64.txt` both end `PASS: 19 checks, 0 failures`; sha256 `1a1c76665f5a013b…` (linux) and `0190ba968e53b943…` (windows) |
| 6a. The jar's model data is self-consistent | PASSING | run `43680833198`: `PASS: every model a blockstate can render resolves through its chain (2603 models, 25048 faces, 3964 textures)`; jar `26.3`, 41 483 720 bytes, sha1 `e877b6a07acd633f…`, verified against Mojang's manifest at test time (`evidence/jar/pin.txt`, `evidence/jar/jarcheck.txt`) |
| 6b. World parity against the real client | NOT DONE | the jar's models and textures are now what draws the world (stage 3, step 3, CI-verified with a picture compared against `docs/reference/jar_world.png`), but no world from a real save has been loaded and compared block by block, and no render has been compared with the real client's |
| 7. Release assets verified by re-download | PASSING | `v0.3.0-pre` (pre-release, tag on `1626ba0`), release run `43695376328`, all four jobs `completed/success`. `RELEASE_VERIFY.txt` (committed, reproduced below): `RESULT: PASS - 3 assets re-downloaded from https://github.com/entitybrian69-bit/Umbra-launcher-/releases/download/v0.3.0-pre and every sha256 matched`, `linux: the downloaded binary passed its self-test`, `windows: the downloaded .exe ran under wine and passed its self-test` |

## The owner's first run of 0.3.0-pre (device evidence, 2026-11-15)

The owner installed `v0.3.0-pre` on a phone: **Mali-G57 MC2**, GLES 3.2
(`V1.R32P1-01EAC0.153…`), 24-bit depth, `highp vs 127^23 fs 127^23`, landscape
2412x1080, density three and a half. It installed, started and drew. Four defects
came back with screenshots, and all four are fixed in 0.3.1:

| What the phone showed | Cause | Fix, and what proves it |
|---|---|---|
| `LOADING WORLD 224%` | the progress divisor counted 219 units for a mesh that takes 1947 | the total is now computed from the structure the stepper walks and clamped in Goose *and* in C; the headless host checks `units == total`, `progress < 1000` before the end and `== 1000` after: `progress: worst 997 permille; units 1947, total 1947` |
| the overlay's first lines sat under the status bar and the clock overlapped them | `getSystemWindowInsetTop()` returns 0 when the window is drawn edge-to-edge, which is how Android 15 lays apps out | insets now come from `WindowInsets.getInsets(systemBars | displayCutout)` with the legacy and cutout values as lower bounds, all four logged with their source; the layout arithmetic moved to `platform/shared/umbra_hud.h` and is tested against a simulated 63 px status bar, a 126 px navigation bar and a 112 px cutout; the emulator smoke test now sets `debug.umbra.insets` and fails if the overlay starts above the top inset |
| only sky behind the overlay | the camera was framed by a formula that put it 55 blocks out on a 2.2:1 screen, and the overlay covered the top half | the distance is computed by fitting the world to the visible part of the screen, the 3D view is shifted out from under the overlay, and the HUD now prints `mesh … verts, … draws` and `cam eye -> look` so "only sky" is diagnosable from a screenshot |
| one screenshot did not show the results | the self-test and benchmark numbers lived only in the session | both are written to `last_selftest.txt` / `last_bench.txt` beside the log, read back at start-up, and drawn as a `LAST RUN` block; the smoke test restarts the app and fails if that block does not come back |

Run 43709489473, the emulator at 1920x1080 with `debug.umbra.insets "0,63,126,0"`:

    insets: L,T,R,B = 0,63,126,0 (modern 0,63,126,0, legacy 0,0,126,0, cutout 0,0,0,0,
            source debug.umbra.insets override) on 1920x1080, density bucket 420 (scale 2.62)
    overlay: button 0 starts at y=999, below the 63 px top inset
    overlay: hud: 11 rows, content ends at 484 px inside a 486 px panel, fits
    camera: eye 47.2 105.2 32.1 look 24.0 88.0 8.0, 37.6 blocks out, fov 55
    benchmark: bench: 653 frames  avg 92.18 ms (10 fps)  1% low 7 fps (135.45 ms)
    relaunch: the previous self-test verdict is on the home screen
    relaunch: the previous benchmark numbers are on the home screen
    crash-detect: kill -9 6368 / the killed run was reported on the next start
    result: PASS (installed, launched, drew, self test tapped, 60s soak, no crash)

`modern 0,63,126,0` beside `legacy 0,0,126,0` on the same frame is the whole bug:
the call the app used answers zero on a window drawn edge to edge, and the one it
uses now answers 63. **None of this has been seen on the owner's phone yet** - it is
CI evidence on an emulator, and the four fixes are `owner-must-confirm` until the
`v0.3.1-pre` build runs on the phone.

## 0.3.1-pre is published and verified

`v0.3.1-pre` supersedes `v0.3.0-pre`, which stays published and untouched.

```
release: https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.1-pre
run:     https://github.com/entitybrian69-bit/Umbra-launcher-/actions/runs/43712127908
commit:  0690ed881cd523abe7a3cd00e5f87089e437847e
asset: umbra-0.3.1-pre-arm64.apk      226171 bytes  http 200  sha256 e54218e7...  OK
asset: umbra-0.3.1-pre-linux-x64       76352 bytes  http 200  sha256 9245e7db...  OK
asset: umbra-0.3.1-pre-windows-x64.exe 172836 bytes http 200  sha256 76f230b7...  OK
RESULT: PASS - 3 assets re-downloaded and every sha256 matched
linux: the downloaded binary passed its self-test
windows: the downloaded .exe ran under wine and passed its self-test
```

`RELEASE_VERIFY.txt` in the repository root is that file, committed by the release
workflow after it re-downloaded each asset from its public URL.

**What is verified:** the work builds, the APK installs and runs on an emulator
with a simulated 63 px status bar, the self-test passes, the benchmark produces the
four-line block, a restart shows the previous run's results, a kill is still
reported as a crash, and the published bytes match their checksums.

**What is CI-only:** everything above happened on an x86_64 emulator with
SwiftShader at density 420. It is not the owner's Mali-G57 at density 3.5.

**What the owner must confirm:** the four fixes on the phone — that the percentage
stops at 100, that no line sits under the status bar, that the island fills the
strip between the text and the buttons, and that the `LAST RUN` block comes back
after closing and reopening the app.

## 0.3.2-pre is published and verified

`v0.3.2-pre` is the build that answers the owner's three findings. `v0.3.0-pre` and
`v0.3.1-pre` stay published and untouched.

```
release: https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.2-pre
run:     https://github.com/entitybrian69-bit/Umbra-launcher-/actions/runs/43726939393
commit:  33958092e1ba8743451d7702510b7547236bb729
asset: umbra-0.3.2-pre-arm64.apk      254787 bytes  http 200  sha256 a0cd23ec...  OK
asset: umbra-0.3.2-pre-linux-x64       76552 bytes  http 200  sha256 c5c2775d...  OK
asset: umbra-0.3.2-pre-windows-x64.exe 176668 bytes http 200  sha256 342590ed...  OK
RESULT: PASS - 3 assets re-downloaded and every sha256 matched
linux: the downloaded binary passed its self-test
windows: the downloaded .exe ran under wine and passed its self-test
```

`RELEASE_VERIFY.txt` in the repository root is that file, committed by the release
workflow after it downloaded each asset from its public URL.

**What is verified:** the work builds from the tag on a clean checkout, the APK
installs and runs on the CI emulator, its GPU self-test passes with 4 147 200
compared pixels, the benchmark produces the six-line block with a `vsync:` verdict,
the device checks are in the log, a restart shows the previous run's results, a
kill is still reported as a crash, and the published bytes match their checksums.

**What is CI-only:** all of it. SwiftShader, x86_64, density 420, no display
cutout, no timer-query extension.

**What the owner must confirm:** that the phone now says `SELFTEST PASS` with a
real pixel count, that the log carries the eight `check:` lines and either a real
`gpu avg N ms` or `gpu n/a`, and that the benchmark's `vsync:` line reports what
the phone actually did.

## 0.3.2 - the three findings from the phone, and the four bugs they found

The owner's `0.3.1` run on the Mali-G57 produced three numbers. Each one had a
cause, and fixing them found four more defects that no emulator run had failed on
because nothing asserted them. Everything below is from run `43724314085`
(commit `a717183`), the emulator at 1920x1080 with `debug.umbra.insets "0,63,126,0"`.

| The phone said | Cause | What the log says now |
|---|---|---|
| `GPU self-test FAIL: 2458665 bad of 4950720 px` | `int` in a fragment shader is mediump (16-bit on Mali), so `x * 255` overflowed past x = 128 and only the 129x129 corner could match: 16641 pixels, against the 16695 the phone's own numbers imply | `self-test: pattern compared, 0 of 2073600 px differ, max channel diff 0` and `SELFTEST PASS (0 bad of 4147200 px, 1773 ms, offscreen)` |
| the run before ended at `SELF-TEST: BEGIN (2292x1080)` and was reported as a crash | five million comparisons and two full-frame readbacks in one frame is five seconds without the main looper: Android force-stopped the app. It was an ANR, not a crash | `self-test: begin (1920x1080), tile 78 rows` … `end after 1773 ms, 32 steps`; a stuck test now ends with `watchdog: 30 s in "<phase>"` |
| benchmark 59 FPS | the display is 60 Hz; the number was the cap, not the GPU | `swap interval 0: accepted by EGL`, `benchmark: uncapped swap interval requested and accepted`, `vsync: uncapped requested`, and `gpu n/a (no GPU timer results)` on the emulator, which has no timer extension |

The four defects found on the way, each of which had already broken a device run:

1. **The comparison read the window, not the offscreen target.** Compare steps run
   one per frame, and the frame loop binds the window again after each step, so
   every tile came from the window and was compared against the pattern:
   `2073600 of 2073600 px differ` (run 43720791540). The target is bound before
   every read now.
2. **The counters were read after they had been reset.** The mismatch count was
   taken, the counters were zeroed, and only then was the checked count read, so a
   self-test reported `3854519 bad of 0 px`. All counters and the first-mismatch
   text are now read before the reset.
3. **The smoke test accepted a failing self-test.** It asserted that the test ran,
   not that it passed. It now requires `SELFTEST PASS`, at least 100k compared
   pixels, and turns the run red on `FAIL` or `SKIPPED`. That gate is what would
   have caught 43720791540 before a release.
4. **`device_checks()` was never called, and the platform hook was erased.** The
   checks were written, reviewed and dead: no `check:` line appeared in any device
   log. And `umbra_app_init`'s memset wiped the swap-interval hook android_main had
   just installed, so the benchmark could only ever say "no platform hook". Both
   are fixed, and `tools/check_c.sh` fails if the call disappears again.

The device log now reads:

```
check: renderer                     Android Emulator OpenGL ES Translator (Google SwiftShader)
check: gl version                   OpenGL ES 3.0 (OpenGL ES 3.0 SwiftShader 4.0.0.1)
check: max texture size             8192 px
check: gpu timer query              none  (not available)
check: shader programs              mesh ok, hud ok, pattern ok, cube ok
check: depth buffer                 24 bits
check: extension string             1412 chars
check: all device checks passed
```

and the benchmark block is six lines, with GPU time and the swap-interval verdict
on their own lines:

```
bench: 1306 frames  avg 45.97 ms (21 fps)
1% low 14 fps (69.79 ms)
median 45.82 ms  worst 77.32 ms
Android Emulator OpenGL ES Translator (Google SwiftShader) | Android OpenGL ES 3.0
gpu n/a (no GPU timer results)
vsync: uncapped requested
```

**What is CI-only.** Every number above is SwiftShader on an x86_64 emulator at
density 420, with a simulated 63 px status bar and no display cutout. It is not the
Mali-G57 at density 3.5.

**What the owner must confirm on the phone.** That the self-test now says
`SELFTEST PASS` with a real pixel count; that its log shows the `check:` lines and
either a real `gpu avg N ms` or `gpu n/a`; and that the benchmark's `vsync:` line
says what the phone actually did.

## Final audit, before `v0.3.2-pre` is published (2026-11-15)

Every line is a command that was run, on commit `da4e8e2` unless stated.

| # | Check | Result |
|---|---|---|
| 1 | `GOOSE=build/bin/goose tools/gen_core.sh` twice in a row | `generated build/gen/umbra_core.c (9664 lines of C from Goose)`; the two files are byte-identical (`diff` prints nothing) |
| 2 | `tools/check_c.sh` | `check_c: FS_PATTERN declares precision highp int`, `check_c: umbra_app_init runs the device checks`, `check_c: both branches parse and type-check, and both platform mains do too` (desktop and `-D__ANDROID__`, plus both platform mains with `-Werror=implicit-function-declaration`) |
| 3 | `tools/build_pc.sh` (headless host) | `PASS: 149 checks, 0 failures`; the same suite passes in CI on `ubuntu-latest` and on `windows-latest` under MSYS2 UCRT64 (run `43725273753`, jobs both `success`) |
| 4 | Android workflow on the audited commit | run `43725273786`: `Build APK (arm64 + x86_64)` success, `Emulator smoke test + screenshot` success, including `SELFTEST PASS (0 bad of 4147200 px, 1788 ms, offscreen)` and `result: PASS (installed, launched, drew, self test tapped, 60s soak, no crash)` |
| 5 | Core workflow (Goose, x86_64 and arm64) | run `43725273775`: both jobs success |
| 6 | Jar workflow (model data) | run `43725273740`: success; the 41 MB client jar is downloaded at test time and never committed (`find . -name '*.jar'` inside the repo: nothing; `.git` pack 14.15 MiB, 3.7 MiB tracked) |
| 7 | Nothing silent left | `check:` lines for renderer, GL version, max texture, timer query, per-program link status, depth bits and extension length; a failure puts the app in the fallback renderer with the reason on screen; the smoke test now fails on `SELFTEST FAIL`/`SKIPPED` or fewer than 100k compared pixels |
| 8 | Docs contract | `DECISIONS.md` D-038 (the shader precision bug, the phased self-test, its costs), `KNOWN_ISSUES.md` corrected where it claimed nothing had run on a phone GPU, `docs/PHONE_TEST.md` rewritten for 0.3.2, this file |
| 9 | Git safety | no force-push, no branch deletion, `main` is still `c10bffc` ("Create blank.yml"), work is on `arena/dd4cb2fb-umbra-launcher`, and the tag is made on this branch |
| 10 | Release safety | `v0.3.0-pre` and `v0.3.1-pre` stay published and untouched; `v0.3.2-pre` is a new pre-release |

**What this audit cannot say.** That the fixes work on the owner's phone: the
emulator is SwiftShader, density 420, no cutout, and `gpu n/a` where the phone may
report real timer results. The parity table is still empty — no world from the
real game has been opened, nothing renders the jar's models, so there is no
honest "1.0" and no Minecraft claim to make. The arm64 `.so` inside the APK is
still never executed by CI.

## The reference screenshot, and why it changed

`docs/reference/emulator_home.png` is now the frame from run 43709489473: the
buttons in one row, the overlay inside a 486 px panel, the world filling the band
between them and the previous run's results on the home screen. The gate still
measures it -- fresh frame, not blank, mean absolute difference under threshold
(`4.53 of 255` between the two shots of that run) -- so it catches a screen that
changes by accident, and an intentional change updates the reference in the same
commit as the reason.

## The first release (gate 7)

```
tag v0.3.0-pre  prerelease=true
url https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.0-pre
SHA256SUMS                       282 bytes
umbra-0.3.0-pre-arm64.apk     214723 bytes  sha256 312bd4ba875d9d38abf0ee6f4a216becfb1b17291a22cab7e969e016659b35f1
umbra-0.3.0-pre-linux-x64      59048 bytes  sha256 ae53bf6dac39c50fd6b92daf5ebccf8d7b80165793bb8854a02e39b6bf12cfbb
umbra-0.3.0-pre-windows-x64.exe 155881 bytes sha256 b89376bc32dadfed8e069c97a22ec5c952476c3808bf4d75a1ba9fb80f2d6915
```

`RELEASE_VERIFY.txt` (committed by the release workflow, run `43695376328`):

```
RESULT: PASS - 3 assets re-downloaded from https://github.com/entitybrian69-bit/Umbra-launcher-/releases/download/v0.3.0-pre and every sha256 matched
linux: the downloaded binary passed its self-test
windows: the downloaded .exe ran under wine and passed its self-test
```

The tag points at `1626ba0`, whose `android` run `43694202675` ended `result: PASS
(installed, launched, drew, self test tapped, 60s soak, no crash)` with `self-test:
pattern 2073600 pixels checked, 0 mismatched` and `self-test: cube 2073600 pixels
checked, 0 mismatched`.

**The caveat that belongs with those numbers:** the APK in the release was built by
the release workflow and is *not* byte-identical to the APK the emulator installed
from the same commit (both 214723 bytes; `312bd4ba…` released, `2163f797…`
emulator-tested). Android builds are not reproducible yet, so the released bytes
were hashed and downloaded back but not installed on a device. The owner's phone
is the first device to run them -- which is exactly why the checklist in
`docs/PHONE_TEST.md` exists.

Three defects were found by this gate and fixed before publishing: a verifier that
built URLs with a leading space and therefore downloaded nothing (D-032), and a
Windows binary that needed `libwinpthread-1.dll` from the machine that built it
(D-034). The withdrawn first attempt is recorded in D-033.

## Verified results (command output, not claims)

### The official jar's model data (run 43680833198, version 26.3)

```
jar: read 41483720 bytes from build/jar/client.jar
jar: 34227 entries
jar: blockstates 1288, models 4192, textures 3964
jar: blockstate model references 10290, distinct models used 2603 (1589 unused)
jar: parent links followed 4176, parents that exist 4176, builtin parents 0
jar: used models with elements 2544, boxes 6128, faces 25048, faces whose texture resolved to a PNG 25048, uv sets 20908, faces naming a key without '#' 6
jar: texture variable hops 2740, inverted boxes (legal) 16, box rotations 1918 (26 with no angle, 0 with no origin)
jar: multipart blockstates 104, weighted variant lists 75
jar: textures decoded 159, sane sizes 159 (5 animated strips), tallest 512 px
jar: problems 0
PASS: every model a blockstate can render resolves through its chain (2603 models, 25048 faces, 3964 textures)
```

What that means concretely: for each of the 2603 models a blockstate can put on
screen, the checker merges the textures of the model and its parents (the child
wins), takes the boxes of the first model in the chain that has any, and resolves
every one of the 25 048 faces — 2740 of them through `#variable` hops — to a PNG
that exists in the jar. Zero faces fail. 3964 textures are present; 159 were
decoded and all are sane sizes (five are animated strips, the tallest 512 px).

The checker runs against a synthetic jar first, on every push, with four planted
faults that it must name (`tools/check_jar.sh`): a blockstate naming a model that
does not exist, a face key no model defines, a parent that does not exist, and a
face texture with no PNG.



### The GPU self-test, on the CI emulator (run 43670787000)

```
app: self-test: target offscreen, pixel(0,0) = 0,0,64, pixel(w-1,0) = 255,255,64
app: self-test: pattern 2073600 pixels checked, 0 mismatched, max channel diff 0
app: self-test: cube 2073600 pixels checked, 0 mismatched
```

Every one of the 2,073,600 pixels of a 1920x1080 offscreen target is compared
with the colour the fragment shader must produce for that `gl_FragCoord`; the
cube test compares the centre of the screen with the shaded cube and the outside
with the clear colour. The same formulas are checked on the CPU (below), so a
broken checker cannot pass the GPU test.

### The PC builds, in CI (run 43674038711)

```
Linux x64 build + headless self-test      completed/success
Windows x64 build + headless self-test    completed/success
```

The Windows job installs MSYS2 UCRT64, builds the pinned Goose compiler from
source, generates the core, compiles `platform/pc/headless_main.c` with
`gcc -O2`, and **runs the resulting .exe on the Windows runner** — so this is a
real Windows x64 execution, not a cross-compile that nobody started. Both jobs
then commit their self-test text and checksums back to the branch
(`evidence/ci/pc-linux-x64.*`, `pc-windows-x64.*`), because job logs and artifact
downloads are not readable from the environment that drives this project.

### The PC headless host (`build/pc/umbra_headless`, rebuilt 2026-11-15)

```
umbra headless self-test
core version: 0.1.0-stage1
mesh: 17783424 vertex bytes, 2222928 index bytes
mesh checks: 0 bad indices, 0 bad normals, 0 positions out of bounds
sliced mesh: 603 calls, worst call 10.21 ms, worst unit 10.21 ms
batches: 542910 + 12822 + 0 = 555732 of 555732 indices
bench: 1000 frames  avg 16.00 ms (62 fps)
1% low 62 fps (16.00 ms)
median 16.00 ms  worst 16.00 ms
headless | Android none
bench: 202 frames  avg 16.83 ms (59 fps)
1% low 10 fps (100.00 ms)
median 16.00 ms  worst 100.00 ms
headless | Android none
PASS: 39 checks, 0 failures
```

The 39 checks cover the mesh invariants, **the sliced mesher producing byte-identical
output to the whole-mesh path**, the format round trips, the benchmark arithmetic
(the average, the 1% low and the median are checked digit by digit against known
frame times, including a run where two 100 ms frames must move the average and
must be reported at their real cost by the 1% low), the self-test's expected
pattern over a whole 64x48 screen, and three checks that the cube verdict actually
rejects wrong pixels — "test the tests".

The machine is `e2b.local`: x86_64, 2 cores, 3 GB, no GPU. 62 fps here is a
CPU-side number — the headless host runs a fixed 16 ms step with no GPU work — and
says nothing about a phone GPU.

### Start-up: meshing in slices, not in one 5-second stall

The emulator once spent **5304.1 ms** meshing the demo world in a single call
(`demo world built in 2.7 ms, meshed in 5304.1 ms`), which on a phone is a frozen
window and a likely ANR. Meshing is now a state machine in Goose
(`demo_mesh_begin` / `demo_mesh_step(budget_us)` / `demo_mesh_finish`) stepped
from the frame loop with `UMBRA_MESH_BUDGET_MS 6`, and the app draws
`LOADING WORLD nn%` until `mesh_state == 2`, ignoring taps meanwhile.

Evidence that slicing changed nothing about the result, from the headless host:
`sliced mesh: 603 calls, worst call 10.21 ms, worst unit 10.21 ms` and
`PASS: 39 checks, 0 failures`, where the new checks compare the sliced bytes
against the whole-mesh bytes. A single call can still overrun the budget by one
mesh unit (one column x pass x section), which is why the emulator smoke test's
ceiling is 1 s on the longest frame, not 6 ms on the budget.

The benchmark line is now four lines so it fits a phone screen, and it carries
what the owner asked to see on the device: average frame time and FPS, the 1% low
(mean of the slowest 1% of frames) as FPS and as milliseconds, the median and the
worst frame.

The HUD is drawn in display pixels scaled by the display density (D-030): at
scale 1 on a 420 dpi screen a capital letter was 3 dp tall and the buttons ran
under the navigation bar. The next run's numbers replace the ones below; until
then this build's overlay is the one described here.

Also new: `platform/android/android_main.c` reads the system insets and the display
density over JNI (`getRootWindowInsets`, `AConfiguration_getDensity`) before
`umbra_app_init` and again on `APP_CMD_WINDOW_RESIZED` / `APP_CMD_CONFIG_CHANGED`,
so nothing is drawn under the status bar or the gesture bar.

### The Goose core, in CI (run 43674038711, gcc on ubuntu-latest, Goose v2026.4 `6c1fbc78`)

```
PASS mem (19 checks)
PASS inflate (97 checks)
PASS zip (137 checks)
PASS png (153 checks)
PASS nbt (196 checks)
PASS region (237 checks)
PASS json (302 checks)
PASS mesh (340 checks)
```

### The APK (CI run 43670787000)

```
apk: android/app/build/outputs/apk/release/app-release.apk
sha256 172983ea522d956fafb7679b557d743721bcede033c213ac7e75e7fd233c7a07
package: name='org.umbra.client' versionCode='1' versionName='0.1.0' compileSdkVersion='35'
native-code: 'arm64-v8a' 'x86_64'
apksigner: Verified using v1 scheme (JAR signing): false
```

Gate 2's step also runs `unzip -t` and fails if either ABI's `libumbra.so` is
missing. Signed with the repository key (DECISIONS.md D-014); v1 signing is off
because minSdk is 24 and v2/v3 cover it.

### The emulator, with sliced meshing and insets (CI, run 43684817720)

```
app: 06:23:22 demo world built in 3.6 ms; meshing starts in slices of at most 6 ms
app: 06:23:22 insets: 0,0,126,0 on 1920x1080, density bucket 420 (scale 2.62)
app: 06:23:22 hud: button 0 at 8,946 size 1904x34 on 1920x1080 (insets 0,0,126,0)   [before D-030/D-031]
app: 06:23:40 startup: meshed in 5621.7 ms over 587 calls (worst call 39.0 ms, worst unit 39.0 ms), longest frame 206.3 ms, frames over 250 ms: 0
mesh: longest frame 206.3 ms (under the 1000 ms budget)
result: PASS (installed, launched, drew, self test tapped, 60s soak, no crash)
```

That is the before/after the owner asked for. Before: one **5304.1 ms** call on the
window thread. After: 587 slices, worst **39.0 ms**, longest frame **206.3 ms**,
**zero** frames over 250 ms, and the whole run still ends `PASS`. The slice count
and the total are bigger than the single call (5621.7 ms vs 4624 ms earlier) --
that is the cost of not freezing the window, and it is paid once at start-up.

The insets are also real now: the emulator reports `0,0,126,0` and a density of
2.62, and the buttons moved from `y 946` under the navigation bar to a layout
that respects it.

### The emulator, at the commit this release is tagged from (CI, run 43689588854)

```
app: 07:26:46 startup: meshed in 5507.8 ms over 596 calls (worst call 71.7 ms, worst unit 69.5 ms), longest frame 182.1 ms, frames over 250 ms: 0
mesh: longest frame 182.1 ms (under the 1000 ms budget)
size: the HUD was laid out for a 1920 pixel wide surface
result: PASS (installed, launched, drew, self test tapped, 60s soak, no crash)
```

Four runs in a row now end `PASS` with zero frames over 250 ms and a longest
frame under a quarter of a second.

### The emulator, after the overlay and surface fixes (CI, run 43688102045)

```
app: EGL up: 1920x1080 GL_VERSION OpenGL ES 3.0 (OpenGL ES 3.0 SwiftShader 4.0.0.1)
app: 07:07:34 hud: button 0 at 25,809 size 1743x63 on 1920x1080 (insets 0,0,126,0)
app: 07:07:59 startup: meshed in 7500.3 ms over 714 calls (worst call 44.3 ms, worst unit 44.3 ms), longest frame 220.7 ms, frames over 250 ms: 0
== phase: display-size ==
size: the HUD was laid out for a 1920 pixel wide surface
result: PASS (installed, launched, drew, self test tapped, 60s soak, no crash)
```

The three buttons are now 63 px tall (24 dp), start at 25 px and stop at 1768 --
left and right of the 126 px navigation-bar strip -- and sit on a visible panel.
`docs/reference/emulator_home.png` was re-taken from this run (D-019); the previous
reference showed 3 dp text with no backgrounds.

### The emulator (CI, run 43670787000, before slicing)

```
emulator: booted in 52 s          android: api 30 (11)    display: 1080x1920
install: Success                  launch: Status: ok
app: goose core initialised
app: EGL up: 1920x1080 GL_VERSION OpenGL ES 3.0 (OpenGL ES 3.0 SwiftShader 4.0.0.1)
app: depth bits 24, vertex highp 127^23, fragment highp 127^23
app: demo world built in 27.4 ms, meshed in 4624.2 ms
app: mesh: 370488 vertices, 555732 indices; batches 542910/12822/0
app: hud: button 0 at 8,946 size 1904x34 on 1920x1080 (insets 0,0,0,0)
tap: self-test button at 8,946 size 1904x34, tapping 960,963 → the app reported a self-test
soak: survived, pid 3172        TOTAL PSS: 80850
```

The two screenshots are committed: `docs/reference/emulator_home.png` (the home
screen: a 3x3-chunk island with trees, the HUD and the three buttons) and
`docs/reference/emulator_selftest.png` (after the GPU self-test). Meshing is
sliced now (see the run above); this section is kept as the before picture.

## How CI evidence is read here

The machine that drives this project cannot download GitHub job logs
(`gh run view --log` returns nothing) and cannot download artifacts (the redirect
to `productionresultssa*.blob.core.windows.net` is unreachable). So the workflow
publishes what it learned two ways: check-run **annotations** for milestones and
failures, and `evidence/ci/` — screenshots, logcat, dumpsys, `summary.txt` —
**committed back to the branch** by the emulator job (DECISIONS.md D-016). Every
number quoted above from CI came through one of those channels.

## Not verified, and must not be claimed

* Nothing has run on a phone GPU: the only device is an x86_64 emulator with
  SwiftShader, a software rasteriser.
* Nothing has run on ARM.
* No world generated by the real game has been opened. No parity numbers exist.
* The `zlib_store` writer is valid zlib but does not compress.
* The release key is public; builds are consistent, not authenticated.

## Next steps, in order

The owner set the order; it survives interruptions.

**Continuing: the brief's items are being worked in its own order.** Items 1 and 2 are
now settled by evidence rather than by argument. Item 1 ("are the phone's textures the
jar's?") is answered twice over: in "Step 6, item 1, the truth" for the case with no jar,
and in "The evidence a phone's copy of the game files is real" for the case where the
phone fetches one -- run `43960566328` downloaded 41 483 720 bytes from Mojang through
the app's own button and drew with them. Item 2 (an edit re-meshes one chunk inside
50 ms) was already met and is host-checked on every push; on the emulator the worst edit
slice is 18.5 ms (`43960566328`) and start-up's frames are attributed in the section
below.

What is left of the brief's item 3 is **threaded meshing for world loading**, and then
item 4 (the player: full-block steps, swimming, sneak, hotbar and inventory, saving
edits) before worldgen parity.

Start-up's long frames are now attributed rather than guessed. Run `43968867039` (android,
success) printed:

```
shaders: 5 programs compiled and linked in 36.2 ms (mesh 7.2, hud 8.8, the rest 20.2)
upload: 25.0 MB of vertices and 3.1 MB of indices in 68.8 ms (409 MB/s)
frame: the first world frame drew in 164.0 ms and the driver held it 90.7 ms
       (glFinish), 436052 vertices over 27 ranges
startup: ... longest frame 208.3 ms, frames over 250 ms: 0
```

The app's own work is 36 + 69 + 164 ms on a software rasteriser whose own benchmark
reports a median of ~85 ms per frame at 1920×1080 (`bench: 689 frames avg 87.18 ms`);
the first world frame is one to two scenes' worth of that, not a stall of the app's.

**Loading got faster while this was being measured, because the measurement said where
the time was.** The worst meshing call was 45.4 ms under a six-millisecond slice — the
slice was a promise the code could not keep, because a unit is not interruptible. Two
changes, in run `43997491638` (android, success):

* The loading slice is 20 ms and the ceiling is the brief's 50 (the host suite measured a
  50 ms slice at 52.33 ms, i.e. over the number the brief names). `demo_place_column`
  filled the vertex and index arenas one `push` at a time; it now appends a 64-element
  run, so the fill is memcpys instead of hundreds of thousands of calls.
* The numbers, on the same emulator, same world:

| | before (43968867039) | after (43997491638) |
|---|---|---|
| start-up mesh | 3805.5 ms over 296 calls | **1391.5 ms over 60 calls** |
| worst meshing call | 45.4 ms | **29.2 ms** |
| worst unit | 45.4 ms | **19.1 ms** |
| worst edit slice | 18.5 ms | **25.3–30.6 ms** |

The 50 ms the brief asks for is now checked, not asserted: the emulator phase fails the
run if the worst loading call exceeds it, and the host suite fails if the worst loading
call exceeds it either (the host runs the app's own 20 ms slice, not a test-sized one).

The hands phase on the emulator, from `evidence/ci/summary.txt` of run `43960566328`
(android, success) -- the same run that fetched the jar:

```
hands: the app answers at 1239,955, so input is 'identity' of the surface
hands: the hotbar selected the slab: player: hotbar slot 4 selected (oak_slab)
hands: looking down at pitch -1
hands: player: break -> 1 (broke grass_block at 25 65 23)
edit: re-meshed 1 of 9 columns in 133.9 ms over 17 calls (worst call 18.5 ms,
      worst slice 18.5 ms), 3 slot(s) changed
edit: the longest slice was 18.5 ms (under the 50 ms an edit is allowed)
hands: player: place -> 1 (placed oak_slab at 25 65 23)
hands: shot-hands.png is 578451 bytes
```

1. **Done:** `v0.3.0-pre` and `v0.3.1-pre` are published, each verified by
   re-download (`RELEASE_VERIFY.txt`), and `0.3.1` ran on the owner's phone.
2. **Done:** gate 4 is closed on ARM at the host-suite level, with the caveat that
   the Android arm64 `.so` inside the APK is still compile-only.
3. **Done, CI pending on the picture.** *Atlas: done* (`core/atlas.goose`, 12 placeholder tiles,
   128x128, padded, mipmapped, magenta for missing, counted; sampled back through the
   real upload path by the on-device self-test: `0 of 256 texels differ`). *Block
   models: the parser and the geometry path are done* (`core/models.goose` parses
   elements/faces/uv/cullface/tintindex/rotation and resolves `#` chains; the mesher
   draws a bound block's geometry from the model's own box; the demo world contains a
   plank slab drawn that way; `goose/modelcheck.goose` parses every block model in the
   real jar in CI). *Still missing:* binding the jar's own blockstates to models at
   load time instead of one built-in slab, and packing the jar's textures. The
   original goal, for reference: blockstates + models + a texture atlas
   packed from the jar's `textures/block`, with padded or extruded tile edges,
   mipmaps that do not bleed colour between tiles, animated textures frozen on
   frame 0, a loud magenta tile for missing textures (counted in a test), and
   cullface, tintindex, shade, element and UV rotation, cutout vs translucent.
4. **A real textured world**, a new screenshot reference, then **worker-thread
   meshing**, then **gate 6b** (world parity, measured match rates).
5. **Extend the on-device GPU self-test** to sample a known atlas tile through the
   production upload path and compare it with the same tile decoded from the jar --
   the earlier bug skipped the atlas upload entirely, and only a test that goes
   through the real path would have caught it.
6. Publish a verified pre-release after **every** stage that changes what the phone
   shows. Never replace a working release with a broken one.
7. **Read the owner's next phone log** against the `0.3.2` claims: `SELFTEST PASS`
   with a real pixel count, the `check:` lines, `gpu avg N ms` or `gpu n/a`, and a
   `vsync:` line that says what the phone did. Anything the phone contradicts
   outranks every emulator number in this file.

## Blockers

None that stop work. This session's sandbox has no JDK, Android SDK/NDK, adb,
GPU or KVM, so the APK, the emulator and the phone-facing checks can only run in
GitHub Actions; that is where gates 2, 3 and 5 run, and where their evidence is
produced.

## Stage 3 is in the working tree: block models and a body to walk with

The atlas was stage 1. This stage adds the two things that make the world more than
a picture:

**Block models.** `core/models.goose` parses a model the way the jar writes one:
elements with `from`/`to`, per-face `texture`, `uv`, `cullface`, `tintindex` and
`rotation`, and `#name` chains resolved with a cycle guard. The mesher can draw one
bound block's geometry from a parsed model instead of a whole cube, and the demo
world uses that for a plank slab, so the model path runs in the shipped build. CI
parses **every** block model in the real client jar with the same parser
(`goose/modelcheck.goose`): `4192 block models parsed, 0 refused`, `1205 elements,
4300 faces`, `3409 faces with an explicit uv, 1078 with a cullface, 122 with a tint
index, 251 rotated`, `3845 models are templates with no elements of their own`.

**A body.** `platform/shared/umbra_player.h` gives the camera a body: a 0.6 x 1.8
box with gravity, a jump, walking speed, and collision against the same block data
the mesher used, so a slab that is drawn half a block tall is also walked on half a
block up (D-041). One finger: drag to look, rest to walk, tap to jump. The emulator
smoke test now taps into the world, holds to walk and drags to look, and fails if
the logged position does not move.

Counts from this machine: host suite `PASS: 174 checks, 0 failures` (was 149 before
the player), core suites `mesh 354`, `atlas 403`, `models 425`.

## What CI proved after stage 3 (run 43737854072, commit 4691a05)

The emulator job passes end to end with the player in it, and its summary says:

```
player: physical display 1080x1920, current display 1920x1080
player: 16:59:24 player: spawned at 24.50 66.01 24.50 (floor 66.00), eye 67.63
player: hold 1 walked 0.20 blocks (24.50,24.50 -> 24.50,24.30)
player: hold 2 walked 1.20 blocks (24.50,24.30 -> 25.70,24.20)
player: a held finger walked the body
player: the drag turned the head (yaw -1)
player: the body is standing on the ground after walking
player: a tap asked for a jump
```

with the rest of the run unchanged: `mesh: 370708 vertices, 556062 indices; batches
543276/12786/0`, `SELFTEST PASS (0 bad of 4147200 px + 256 atlas texels, 1977 ms,
offscreen)`, `result: PASS (installed, launched, drew, self test tapped, 60s soak, no
crash)`.

Two of those lines are worth reading twice. `hold 1 walked 0.20 blocks` is the body
walking into a full-block rise and stopping: a half block is stepped over, a whole
block is a wall, which is the rule the host checks encode. And the benchmark on the
emulator is `1207 frames avg 49.77 ms (20 fps), 1% low 12 fps` with `vsync: uncapped
requested` — that is SwiftShader, the emulator's software renderer, and it is the
honest number for it, not for a phone.

## Stage 3, step 3: the jar's own models and textures draw the world

`core/jarpack.goose` builds the pack from the client jar at test time (D-042):
`jp_build_models` and `jp_build_blockstates` walk every entry under
`assets/minecraft/models` and `.../blockstates`, `ms_link_models` binds each rule to a
model (qualifying a name with no namespace, because the jar writes `block/oak_slab` and
the store writes `minecraft:block/oak_slab`), and `jp_build_atlas(16, 2)` decodes every
texture the models name into one padded atlas, frame 0 for animated strips. The mesher
then draws blocks from that pack; `goose/jrender.goose` draws the same demo world the
phone draws, on the CPU, through the same batches in the same order and with the same
camera fit as `platform/shared/umbra_camera.h`, and writes `evidence/jar/world.png`.

Measured on the host, over a synthetic jar that has the real one's shape but invented
colours (`tools/gen_fake_jar.py`, no network, no game data):

```
jr: jar 623129 bytes
jr: models 1115 built, 1115 in the store, 0 refused
jr: blockstates 528 built, 528 in the store, 1731 rules linked to a model
jr: 6672 faces in the models, 469 texture paths
jr: atlas 512x512 tile 16 gutter 2 cells 484
jr: textures used 469, decoded 468, missing 1, animated 0
jr: blocks drawn from a model 1498125, faces 454261, blocks whose blockstate had no model 0
jr: vertices 385644, triangles 192822, batches 545022/33444/0
jr: bounds x 0..48 y -64..76 z 0..48, camera 37 blocks out, looking at y 58
jr: drawn triangles 192822 of 192822, clipped 0
jr: coverage 851 permille of the frame (441550 of 518400 px), sky 76850
jr: hues green 364026, blue 48, brown 62758, other 14718, dark 118341, missing-tile magenta 0
jr: atlas texels compared with the jar's PNGs: 6144 sampled, 0 differ
jr: PASS - a world drawn with the jar's own models and textures
```

That last line is the check that matters most and the one that is easy to fake: every
tile the atlas holds is compared, texel for texel, against the same PNG decoded
straight out of the jar, so a wrong tile rect, a mipmap that bled its neighbours in, a
gutter overwritten into the art, or an animated strip uploaded whole all fail here.

The same renderer, in CI, over the real pinned client jar (26.3, 41 483 720 bytes,
downloaded at test time and never committed), run `43790227726`:

```
jr: models 4192 built, 4192 in the store, 0 refused
jr: blockstates 1288 built, 1288 in the store, 10290 rules, 4 linked here, 0 with no model at all
jr: atlas 1024x1024 tile 16 gutter 2 cells 1225
jr: textures used 1214, decoded 1213, missing 1, animated 52
jr: grass colormap 256x256, 262144 bytes, sampled at 51,174
jr: grass tint 146,189,89 from the jar's colormap
jr: coverage 849 permille of the frame (440486 of 518400 px), sky 77914
jr: hues green 170092, blue 101, brown 142776, other 127517, dark 129958, missing-tile magenta 0
jr: atlas texels compared with the jar's PNGs: 6144 sampled, 0 differ
jr: PASS - a world drawn with the jar's own models and textures
```

and the picture gate (`evidence/jar/world-shot.txt`, same run):

```
evidence/jar/world.png: 960x540
mean absolute difference from the reference: 0.00 of 255 (worst cell channel 0)
PASS: the jar-drawn world matches the reference
```

The reference is `docs/reference/jar_world.png`, committed by the previous jar run
(`43789629651`) and compared unchanged by this one. The picture is a Minecraft world:
grass tops with the vanilla plains tint `146,189,89`, dirt sides, oak logs, leaves,
stone. **This is a CI-verified picture drawn from the real jar**, and it is what
`v0.3.5-pre` is published on.

**What is proved, and what is not.** CI-verified: the pack builds from the real jar,
every blockstate rule resolves to a model, the world draws, the atlas is the jar's
pixels texel for texel, and the picture matches its reference. Host-verified: the same
path over a synthetic jar on every push, so a regression shows up without waiting for
a jar download. The picture the phone shows is still the placeholder
atlas (D-039) with one bound model (D-040): the phone has no jar and cannot have one,
so the jar-drawn world is a CI picture until the app is given the pack from a file it
is allowed to read.

## 0.3.6-pre is published and verified

Tag `v0.3.6-pre` at `68fc892`, release run `43809670666` (success), verification run
`43809674028`:

```
asset: umbra-0.3.6-pre-arm64.apk          395075 bytes  sha256 f1aac82e...  OK
asset: umbra-0.3.6-pre-linux-x64          142808 bytes  sha256 65f463af...  OK
asset: umbra-0.3.6-pre-windows-x64.exe    242245 bytes  sha256 c8a2797b...  OK
RESULT: PASS - 3 assets re-downloaded ... and every sha256 matched
linux: the downloaded binary passed its self-test
windows: the downloaded .exe ran under wine and passed its self-test
```

The five runs on the branch at the *same commit* `68fc892` are green - `core`
`43809663947`, `pc` `43809663846`, `android` `43809663841`, `world` `43809663826`, `jar`
`43809664041` - so the commit the tag was cut from is green in full.

The tag push also started a second set of runs (`ref=v0.3.6-pre`), and `core`, `pc`,
`world` and `android` failed in those. The failing step is "Commit the evidence", not a
test: a tag-triggered run has `GITHUB_REF_NAME` set to the tag, so `tools/commit_evidence.sh`
tried to push a commit to `v0.3.6-pre` and a tag cannot receive one. It now says so and
stops when the run was triggered by a tag (the artifacts still carry the evidence), so a
green release cannot look red for a reason that has nothing to do with the code.

What changed for the phone since `0.3.5-pre`: it can break and place blocks, with five
hotbar slots and two action buttons that are drawn from the arithmetic the taps are tested
against, at a size a finger can hit. The emulator run of that same code did it: `broke
grass_block at 25 65 23`, re-meshed, `placed oak_slab at 25 65 23`.

## Stage 3, step 4: a real world, read twice

`goose/worldload.goose` reads a save the way the renderer does: every `region/*.mca`,
every chunk's NBT, `column_from_nbt` into the same `ChunkColumn` the mesher draws, and
then one record per non-air block - position, name, properties - in a fixed order (y,
then z, then x) folded into an FNV-1a 64 hash per chunk. `tools/world_oracle.py` is a
second implementation of the same format, written from the description rather than from
that code, and prints the same lines. `tools/check_world.py` compares them and reports a
match rate per chunk and per block.

The synthetic world (`tools/make_test_world.py`, generated here in Python, no game data)
agrees exactly, on every push:

```
goose.txt: 4 chunks, 24673 blocks, 7 states
oracle.txt: 4 chunks, 24673 blocks, 7 states
chunks that agree: 4 of 4 (100.00%)
blocks in agreeing chunks: 24673 of 24673 (100.00% of every non-air block in the save)
block states that agree: 7 of 7
detail records that agree: 24673 of 24673 (100.00%), block by block
PASS: two independent readers agree on every block of all 4 chunks
```

The real half is the `world` workflow: `tools/fetch_server.sh` downloads the pinned
server jar from Mojang and checks it against the version JSON, `tools/gen_server_world.sh`
runs it with a fixed seed until it says `Done`, stops it cleanly, and the same two
readers then read *that* save. The server jar and the save are never committed.

**State: DONE and CI-verified on a real, server-generated 26.3 world** (run
`43808551824`, step "Read the real world twice and compare it block by block" success):

```
worldload: region dir build/server/run/world/dimensions/minecraft/overworld/region
worldload: chunks 529, non-air blocks 843609, states 45, region files 4, read errors 0
oracle:    chunks 529, non-air blocks 843609, states 45, region files 4
chunks that agree: 529 of 529 (100.00%)
blocks in agreeing chunks: 843609 of 843609 (100.00% of every non-air block in the save)
block states that agree: 45 of 45
PASS: two independent readers agree on every block of all 529 chunks
PASS: the world the server generated is read the same way twice
```

The same step at the branch tip (run `43824520067`) gives the same verdict on a different
world: `529 of 529` chunks, `844904 of 844904` blocks, `44 of 44` states, `100.00%`. The
numbers move run to run because the server picks a different spawn each time; what is
constant is that two independent readers agree on every block of every chunk.

It took six runs and five separate causes, each found from CI's own output rather than
guessed. They are recorded here because they are the reason the format code now reads what
the game writes. The first cause: run `43800033517`
(commit `764da22`) failed at step 8 with

```
server pid 2857, waiting up to 600s for it to finish generating
ERROR: the server exited before it said it was done
```

and no log tail, because the script changed into the run directory and then handed java a
*relative* jar path, so java exited at once with "Unable to access jarfile" - and the tail
helper looked for `build/server/run/...` from inside `build/server/run`, so it printed
nothing either. Both are fixed: the jar and the run directory are absolute (`realpath`)
and the failure paths print the server's own log tail. The fixed script is host-verified
here against a stub `java` on `PATH`: a fake server that prints `Done (1.9s)` and writes
`world/region/r.0.0.mca` gives `PASS: the real server generated a world with 1 region
file(s)` with `-jar /tmp/fakejar.jar` absolute; a missing jar gives `ERROR: no server jar
at ...`; a java that dies immediately now prints its log (`java.lang.OutOfMemoryError:
Java heap space`) instead of nothing.

The second cause, from run `43801790348`: the fixed script printed the server's own log
and it said

```
Error: LinkageError occurred while loading main class net.minecraft.bundler.Main
        java.lang.UnsupportedClassVersionError: net/minecraft/bundler/Main has been
        compiled by a more recent version of the Java Runtime (class file version 69.0),
        this version of the Java Runtime only recognizes class file versions up to 65.0
```

- the workflow installed Java 21, and 26.3's bundler is class file 69 (Java 25). The
version JSON already says this (`server needed Java 25`, printed by `fetch_server.sh` on
every run); `fetch_server.sh` now writes that number to `build/server/java_major.txt` and
the workflow installs *that* major through a step output instead of a hard-coded 21.

The third cause, from run `43802948052`: with Java 25 the server finally ran, generated the
world and said `Done (3.168s)`, and still wrote **no region files**:

```
world generated after 14s; stopping the server so it saves
server exit status 143
[04:18:11] [Server thread/INFO]: Saving chunks for level 'ServerLevel[world]'/minecraft:overworld
region files written: 0
ERROR: the server wrote no region files
```

- `exit status 143` is SIGTERM, and the vanilla server does not convert that into a clean
  stop: it was killed in the middle of its own save, which is why `level.dat` existed and
  no `region/*.mca` did. The script now runs the server with RCON on loopback
  (`enable-rcon`, port 25575, a throwaway password) and `tools/rcon.py` sends the documented
  `stop`; SIGTERM stays only as a fallback, and the log says which one happened. Host-verified
  against a stub `java` that speaks RCON: clean stop, `region files written: 1`, `PASS`; and
  against one that ignores RCON: `WARNING: rcon did not answer`, `exit status 143`, the loud
  region error. `tools/rcon.py` itself is checked against a fake RCON server (auth, command,
  `stop` closing without an answer = success), a refused password and no server at all.

The fourth failure, from run `43803520288`: **the world was generated and saved**
(`PASS: the real server generated a world with 4 region file(s)`, `2.4M world`), and step 10
failed instead:

```
worldload: FAIL cannot list build/server/run/world/region
```

- 26.3 keeps the overworld's regions in
  `world/dimensions/minecraft/overworld/region/`, not `world/region/`. Both readers now ask
  for the classic path first and then the 26.3 one, print which one answered
  (`worldload: region dir ...`, `oracle: region dir ...`), and both are host-checked on the
  synthetic world in *both* layouts (classic `4 of 4 chunks`, and the same world copied into
  `dimensions/minecraft/overworld/region` gives the same 24673 blocks and `PASS`). The next
  run is the first one that will read a real save.

The fifth run (`43803905956`) got past that and failed on the data itself:

```
worldload: region dir build/server/run/world/dimensions/minecraft/overworld/region
worldload: chunks 529, non-air blocks 0, states 0, region files 4, read errors 0
worldload: PASS - every chunk in the save was read
oracle: ... ValueError: not enough values to unpack (expected 2, got 1)
```

- the save is real and the region files are understood (529 chunks, 4 files, no read errors),
  but the *chunk* format is not the one either reader expects: not one non-air block in any
  chunk, and the oracle raised. The synthetic world those readers were built against was
  written by my own generator, so it only proves they agree with me, not with the game.
  Two changes: the loader now **fails** when it reads chunks and finds no blocks (a save
  full of empty chunks is not an empty world, it is a reader that does not understand the
  file - the old message said PASS), and the `world` workflow now dumps the real chunk's
  *shape* - keys, tag types, list lengths, no block data - into
  `evidence/world/chunk-shape.txt` with `tools/dump_nbt_shape.py`, so the format is read
  from the file rather than guessed. Both readers still pass on the synthetic world
  (`24673 of 24673`, `PASS`) in the classic and the 26.3 directory layout.

The shape dump from that run named the cause:

```
  sections: 24
  section[0]:
    compound with 3 keys
      block_states: compound
        compound with 1 keys
          palette: list len 1
  palette entry:
    string minecraft:air
```

- a 26.3 palette entry is the **bare block name**, not a `{Name, Properties}` compound, for
  every section whose states have no properties. `resolve_palette` called
  `state_name_text` (which reads `Name`) on a string, got nothing, and interned air for
  every entry: 529 chunks, not one block, and a PASS. The biome palette had handled both
  forms since it was written; the block palette now does too, and the Python oracle accepts
  both as well (it used to raise on a string). The synthetic world can now be generated in
  either form (`tools/make_test_world.py <dir> <radius> string`), and CI reads **both** on
  every push, so a reader that only understands the classic form fails here instead of
  passing on the real save. Host: the string-form world gives the same
  `4 chunks, 24673 blocks, 7 states` and `PASS`.

The next run read the real world with both readers and they **disagreed**, which is the
comparison doing its job:

```
worldload: chunks 529, non-air blocks 958903, states 30, region files 4, read errors 0
oracle:    chunks 529, non-air blocks 732557, states 29, region files 4
```

- that is the bit packing of a paletted container. Since 1.16 values run on across a
  64-bit word boundary, so a section is `ceil(4096 * bits / 64)` longs; before that every
  word started a new value, so it was `ceil(4096 / (64 / bits))`. The two are the same
  bytes at 4 bits and different at 5, 6 and 7 - and the synthetic world had 7 states, so
  every section was 4 bits and nothing could show it. The Python side assumed the old
  padding, and the Goose side's test for it could never be true (`count <` a contiguous
  length is not a property of a padded array), so it read every padded section as
  contiguous. Both now choose by length, and the generator can write either packing and a
  palette wide enough to matter. Host, all three flavours, both readers:
  `string` `24673` blocks `7` states, `compound`/20 states `24777`/`27`, `padded`/20 states
  `24777`/`27`, every one `100.00%` and `PASS`. The workflow now reads all four synthetic
  flavours on every push.
- the comparison script also died with an `IndexError` instead of reporting; it now prints
  the lines it cannot read (the first real dump had a `block` line with an empty name,
  which is the next thing to look at).

The sixth cause, from run `43808066207`, was the palette entry itself. The hexdump of the
bytes:

```
08 00 00 00 0f 6d 69 6e 65 63 72 61 66 74 3a 73 ...
08 00 02 69 64 00 14 "minecraft:oak_leaves" 0a 00 0a "properties" ...
```

- in a compound palette, 26.3 writes `{id: <name>, properties: {...}}` for a state that has
  properties, and **a compound with a single member whose name is empty**, `{"": <name>}`,
  for one that does not. Neither reader knew either form. Both now read four forms - the
  classic `{Name, Properties}`, the bare string, `{id, properties}` and `{"": name}` - and
  the generator can write the 26.3 pair, so CI reads five flavours on every push
  (`string`, `compound`, `id` x `contiguous`, `padded`), each at `100.00%`.

**A real world is now read, twice, with full agreement.**

## Step 5 in the working tree: hands (break and place), host-verified

The phone had no way to change the world. It has one now, and it is the same code path
the game uses in the only way that matters: a ray from the eye, a block of the world, and
a re-mesh of the columns that changed.

- `goose/core/demo.goose`: `demo_column_of`, `demo_block_at`, `demo_set_block`,
  `demo_is_air`, `demo_raycast` (Amanatides-Woo DDA, 512 steps, `RayHit.face` in the
  mesher's face order 0 -Y, 1 +Y, 2 -Z, 3 +Z, 4 -X, 5 +X), `demo_face_neighbour`.
- `goose/main.goose`: the hotbar (`umbra_hotbar_count/selected/name/select`), the act
  (`umbra_player_act(kind, eye, dir, reach)` -> `1` changed, `0` nothing in reach, `-1`
  refused, `-2` busy meshing), `umbra_act_text`, `umbra_player_target`, `umbra_block_at`,
  `umbra_set_block`. Default hotbar: grass_block, dirt, stone, oak_log, oak_slab.
- `platform/shared/umbra_hud.h`: five 40 px slots bottom-centre above the inset, two
  action buttons (BREAK, PLACE) stacked bottom-right, and hit tests that use the same
  arithmetic as the drawing.
- `platform/shared/umbra_app.c`: the taps, the drawing, the "hands:" overlay line, and the
  re-mesh. An edit does not blank the world: the old mesh stays uploaded until the new one
  is complete, which matters because a whole-world re-mesh is about 5 s on the emulator
  and there is no per-column cache yet (D-043).

Host evidence (`platform/pc/headless_main.c`, `PASS: 207 checks, 0 failures`, was 174):

- a ray from above the world hits the grass block by name (`minecraft:grass_block`);
- breaking it returns `1`, says `broke ...`, the cell changes, the re-mesh finishes and the
  mesh size differs;
- placing the selected slab returns `1` and the cell then holds `minecraft:oak_slab`;
- a ray that reaches nothing returns `0`; a placement that would land outside the world
  returns `-1`;
- the five slots are on screen at 1080x1920 with phone insets, 1920x1080 and 800x1280,
  never overlap the action buttons, and a tap in the middle of a slot or a button hits
  exactly that slot or button.

The emulator run has a new `hands` phase that reads the rects the app logs, taps the slab
slot, drags to look down, taps BREAK (fails the run if the world did not change), waits
for the re-mesh, then taps PLACE.

Its first run (run `43801790421`, commit `325594e`) failed, and both findings are fixed
and host-tested but not re-run:

1. **The controls were too small to tap.** The hand controls took their size from the
   overlay text scale, which shrinks to fit its rows: on the CI emulator that scale is
   1.65, so a hotbar slot was `23x23` px - about 1.4 mm on a 420 dpi panel. They now have
   their own scale, `umbra_hud_hand_scale`, a 44 dp slot (the smallest target a finger can
   reliably hit) shrunk only if the row would take more than 72% of the screen's short
   side, and the action buttons moved above the hotbar row because at 44 dp they overlapped
   it on a 1080-wide screen. Host-checked at 420 dpi on 1080x1920 and 1920x1080 and at
   160 dpi on 800x1280.
2. **`input tap` and the app do not share a pixel frame.** The activity is landscape
   (surface `1920x1080`) inside a portrait panel (`1080x1920`), so the slot's centre
   `1015,1054` was sent as display coordinates and arrived at the app as a completely
   different point: the tap became "player: tap, jumping", not a selection. The phase now
   tries the four rotations of the same surface point and keeps the one the app answers
   (logged as `the app answers at x,y, so input is 'rotNNN' of the surface`); every later
   tap and the look-down drag go through that frame.

## Parity table (what is and is not the same as the game)

| Thing | State | Proof |
|---|---|---|
| Anvil regions, NBT, PNG, zip, inflate | tested | `region 237`, `nbt 196`, `png 153`, `zip 137`, `inflate 97` checks |
| Block models: every model in the jar parses | yes | `4192 block models parsed, 0 refused`, `1205 elements, 4300 faces` (jar 26.3, CI) |
| Models are drawn from their geometry | every block, from the jar | `blocks drawn from a model 1498125, faces 454261` over the synthetic jar, host-verified; the demo slab's 6 faces, `y+0.5` top and culled bottom are still host-tested (`mesh 354`) |
| Binding the jar's blockstates to models at load | yes, host-verified | `1731 rules linked to a model`, `0 refused` (synthetic jar); the real jar runs in the `jar` workflow (D-042) |
| Textures from the jar | yes, and since 0.3.7 the phone can fetch the jar itself: run `43960566328` downloaded it through the app's own button and drew the world with it (see the evidence section) | real jar 26.3: atlas 1024x1024, 1225 cells, 1214 textures used, 1213 decoded, 1 missing, 52 animated; `6144 sampled, 0 differ` against the jar's own PNGs (run 43831301517). The phone loads a jar at start-up (`UMBRA_JAR`, `<files>/client.jar`, `/data/local/tmp/umbra-client.jar`) and the GPU self-test compares its 256 sampled atlas texels with the jar's decoded pixels |
| A world drawn from the jar's models and textures | yes, with numbers | demo picture: `evidence/jar/world.png`, `0.00` from its reference. **A save read from disk:** `evidence/jar/save.png` + `docs/reference/jar_save.png`. **The world the real server generated:** `evidence/world/real.png` + `docs/reference/real_world.png` -- 156 chunks, 503215 non-air blocks, **26240715 blocks drawn from a model, 0 with no model**, 328628 triangles drawn of 328628, `missing-tile magenta 0`, coverage 680 permille (run 43831301517) |
| A body you can walk with | yes | 24 host checks, and the device run above |
| Breaking and placing blocks | yes, host-verified **and device-verified** | 36 host checks over the ray, the edit, the re-mesh, the 44 dp target size and all three layouts; the emulator `hands` phase breaks and places on the device (run `43960566328`) |
| Water, ladders, sneaking, swimming, mobs, survival, multiplayer | **no** | not implemented |
| Reading a world from a real save | **CI-verified on a real 26.3 save** | `529 of 529` chunks, `843609 of 843609` blocks, `45 of 45` states, two independent readers, run `43808551824`; plus five synthetic flavours on every push |
| Rendered world matches the real client | **not measured** | gate 6b second half: nothing compares two renders yet |
| An edit re-meshes only its own chunk | yes, host-verified | per (pass, column) ranges: an edit re-meshes `1 of 9` columns (`2 of 9` on a chunk border), `73` or `145` units instead of the world's `649`, and the patched geometry hash equals a mesh built from scratch (`5753a44b6995c9bd`, 556062 indices) |
| An edit never blocks a frame for 50 ms | yes, host-verified | worst step call `7.1 ms`, worst single section `2.5 ms` in the PC suite; the emulator run reads the same numbers out of `edit: re-meshed ...` and fails above 50 ms |
| Threaded meshing | **no** | one step per frame on the render thread; the pieces are now small (a section, or one column on an edit) so moving them to a worker is a change of thread, not of algorithm |

## Step 6, item 1: is the world on screen drawn with the jar's textures and every block's own model?

It was not, and the gap was in two places. The CPU renderer in CI drew with the jar
(`goose/jrender.goose`); the phone did not — it uploaded a twelve-tile placeholder atlas
(D-039) and meshed the demo world with a single bound model. A world loaded from a real
save had never been drawn at all.

Now:

* **The phone loads a jar and everything follows from it.** `umbra_jar_load` (goose/main.goose)
  opens the jar, builds every model and blockstate, links them, packs the atlas from the
  jar's own PNGs, sets the tile UVs and the colormap tints, and switches the mesher to the
  model store. It is all-or-nothing: a jar that fails changes nothing, so the app can never
  draw half a pack. The app looks for `UMBRA_JAR`, then `<files>/client.jar`, then
  `/data/local/tmp/umbra-client.jar`; it logs which source it got and the self-test verdict
  names it (`atlas from the jar` / `atlas placeholder`).
* **The on-device texel check is now the jar's texels.** The existing self-test samples one
  atlas tile through the production GL path and compares 256 read-back texels with the same
  tile's decoded pixels; both sides now come from the jar. `tools/emulator_smoke.sh`
  pushes the jar, then requires: the jar loaded, `atlas: source is the client jar`,
  `atlas from the jar` in the verdict, and `atlas 0 of 256 texels differ`.
* **A save is drawn, not just read.** `goose/core/savegame.goose` turns a save directory
  into world columns (both `region/` and `dimensions/minecraft/overworld/region/`), and
  `jrender` takes one as a fifth argument (an optional chunk radius sixth). The renderer is
  deterministic: two runs on the same save produce the same PPM, and the picture is held to
  a recorded reference by `tools/check_world_shot.py`.

The numbers, from run `43831301517` (`world`, success) on the world the real 26.3 server
generated, drawn with the real jar:

```
jr: models 4192 built, 4192 in the store, 0 refused
jr: blockstates 1288 built, 1288 in the store, 10290 rules, 4 linked here, 0 with no model at all
jr: atlas 1024x1024 tile 16 gutter 2 cells 1225
jr: textures used 1214, decoded 1213, missing 1, animated 52
jr: save 4 region file(s), 156 chunks, 503215 non-air blocks, 0 read error(s)
jr: blocks drawn from a model 26240715, faces 13815486, blocks whose blockstate had no model 0
jr: drawn triangles 328628 of 328628, clipped 0
jr: coverage 680 permille of the frame (352845 of 518400 px), missing-tile magenta 0
jr: atlas texels compared with the jar's PNGs: 6144 sampled, 0 differ
jr: PASS - a world drawn with the jar's own models and textures
```

That is the answer to the question: 26 240 715 blocks of a real save's 156 chunks, every
one of them drawn from its own model, with zero blocks whose blockstate had no model, and
the atlas that draws them checked texel-for-texel against the jar's PNGs. The same gate
renders the synthetic save (`evidence/jar/save.png`) and the demo world
(`evidence/jar/world.png`, `0.00` from its reference).

**A defect this found:** the phone copied each column into world space with
`y: src.y + oz` — the z offset added to the *height*. Three of the four columns floated 16,
32 and 48 blocks above the ground since commit `2a36f1e`, and the host tests could not see
it because both the whole-mesh and sliced paths had the same bug. Fixed, with the comment
saying so; the headless suite now also checks that every column's vertices stay inside the
chunk they belong to.

**Not claimed:** the atlas comparison is between the app's own decode and the GPU's
readback of it — it proves the upload, the row order and the packing, not that Mojang's
art is reproduced exactly beyond the 6144 sampled texels. The picture references were
recorded on the first run; the next run compares against them, which is where the
similarity number comes from.


## Step 6, item 1, the truth: the phone was drawing placeholders, and why (2026-11-16)

The question was whether the world on screen is drawn with the jar's real textures
and each block's own model, or with placeholders. The answer, read off the code and
the runs rather than assumed:

**On the CI emulator: the jar's. On the owner's phone before 0.3.7: placeholders.**

The app loads a jar only from one of three places (`jar_try()` in
`platform/shared/umbra_app.c`): `$UMBRA_JAR`, `<files>/client.jar`, or
`/data/local/tmp/umbra-client.jar`. The emulator run works because
`tools/emulator_smoke.sh` pushes the jar to `/data/local/tmp` with adb, and the log of
run `43870808001` (evidence commit `a323a40`) says so in the app's own words:

```
jar: pushed 41483720 bytes, device says 41483720
app: 13:00:21 jar: /data/local/tmp/umbra-client.jar, 41483720 bytes: 4192 models, 1288 blockstates, 1214 textures (1 missing) -- the atlas and the models are the jar's
app: 13:00:21 atlas: source is the client jar
self-test: SELFTEST PASS (0 bad of 4147200 px + 256 atlas texels, 4283 ms, offscreen, atlas from the jar)
```

A phone has no adb, the app had no way to be given a file, and the manifest had no
permissions at all: so on the owner's phone `jar_try()` found nothing and the app
drew the twelve-tile placeholder set (`atlas: source is the placeholder set`). Every
screenshot of a phone home screen so far is the placeholder atlas. That is the truth
this section exists to state, and it is the defect 0.3.7 fixes.

What was already true, and stays true: the jar path itself is complete. With a jar,
all 4192 models and 1288 blockstates are parsed and linked, the mesh asks the model
store for each block's own model (blockstates, variants, multipart, rotations,
tints), the atlas is packed from the jar's own PNGs, and the GPU self-test compares
256 of its texels with the jar's decoded pixels through the real upload path. Nothing
about the drawing was a placeholder when a jar was present; the phone simply never
had one.

## 0.3.7: the phone can now get the game's files (D-043)

The in-app screen the brief asks for, and what it does:

* **Download from Mojang.** One permission (`INTERNET`), one button, one URL: the
  pinned object the manifest names, `.../objects/e877b6a0…7b87/client.jar`, 41 483 720
  bytes. The network call is Java's `HttpURLConnection` -- the NDK ships no TLS client
  -- in `org.umbra.client.UmbraNet`, the app's only Java.
* **Import a jar you already have.** `ACTION_OPEN_DOCUMENT`, copied into the app's
  private directory. This is also why the app's activity is
  `UmbraNet$UmbraActivity` and not `android.app.NativeActivity`: the picker answers
  through `onActivityResult()`, which NativeActivity does not implement.
* **Checked before use, or not used.** A download (and a picked file) lands in
  `client.jar.part`, and only becomes `client.jar` after it passes three checks: it is
  a zip, it is the pinned size, and its sha1 is the pinned `e877b6a0…`. The digest is
  computed by a new Goose SHA-1 (`goose/core/sha1.goose`) checked against the
  published FIPS/RFC vectors (`PASS sha1 (30 checks)`). A file that fails is deleted
  and the screen says which of the three failed.
* **The world follows.** A verified jar is loaded, the atlas re-uploaded, and the
  world re-meshed from the jar's models -- the same path start-up takes.
* **Never shipped, never published, never in the repository.** The jar is in the
  app's private files directory, is removed by uninstalling Umbra, and `.gitignore`
  and the CI steps were already built around not committing it.

The jar is fetched by the *app*, at the owner's tap, from Mojang, on the owner's
phone, after the screen says Java Edition ownership is the condition. Nothing about
the download is in the repository, and no byte of it is redistributed.

## The evidence a phone's copy of the game files is real

Run `43960566328`, evidence commit `4b0a817`. The emulator phase `gamefiles` wipes the
app's private directory, deletes the jar the harness normally pushes, starts the app,
and then does what an owner does: it reads the download button's own logged rectangle,
taps its centre, and waits. The device is on the runner's network; the jar that arrives
is Mojang's, over TLS, through the APK's own Java.

```
gamefiles: the screen is up; jar path /data/user/0/org.umbra.client/files/client.jar,
           41483720 bytes pinned (sha1 e877b6a0…7b87), a jar is not here
gamefiles: button 0 at 35,484 size 435x78, centre 252,523
gamefiles: tapping 252,523
gamefiles: downloading 41483720 bytes from Mojang
gamefiles: the download finished: 41483720 bytes in
           /data/user/0/org.umbra.client/files/client.jar.part
gamefiles: the file is the pinned jar: 41483720 bytes, sha1 e877b6a0…7b87
gamefiles: /data/user/0/org.umbra.client/files/client.jar is now the app's client jar
           (41483720 bytes, sha1 e877b6a0…7b87)
jar: /data/user/0/org.umbra.client/files/client.jar, 41483720 bytes: 4192 models,
     1288 blockstates, 1214 textures (1 missing) -- the atlas and the models are the jar's
gamefiles: the jar in the app's own directory: -rw------- 1 u0_a167 u0_a167 41483720
           /data/user/0/org.umbra.client/files/client.jar
```

`atlas: source is the client jar` follows the adoption, and the phase asserts it: the
atlas on screen after the download is the downloaded jar's, not the placeholder set.
That is item 1's claim made true on a device for the first time -- **with no jar pushed
by the harness and nothing in the app's directory, the app fetched the game's own files
and drew with them.**

The same run is green on every other gate (`pc`, `core`, `world`, `jar`), and the
emulator's own verdict is `PASS (installed, launched, drew, self test tapped, the
game-files screen fetched the jar it needs, 60s soak, no crash)`.

Six device-only faults stood between the code and that line. Each one is now also a host
check, because on a desktop build none of them is visible:

| Fault (run) | What the device said | The check that now catches it |
|---|---|---|
| `am start` with a class but no package (43922373288) | `Bad component name` | — |
| package-relative class (43925231546) | `Error type 3 … does not exist` | — |
| `umbra_app_init`'s memset erased the platform hooks (43946503664) | `jar: none found`, the screen never opened | `check_c.sh` reads init for the five save/restore pairs |
| `JNI_OnLoad` is never called by `NativeActivity` (43951429395) | `no Java network class in this APK` | `check_c.sh` requires `net_init(state->activity)` |
| `FindClass` on a native thread sees only system classes (43953686713) | `UmbraNet is not in this APK` on an APK that has it | `check_c.sh` requires the activity's class loader |
| `pickAndCopy`'s `String[]` written as `String`; Java appending a second `.part` (43956343069, 43958738406) | `missing a method`, then `could not be read back` | `check_jni_signatures.py` compares every descriptor with the Java source |

The placeholder sentence in item 1 is still true for a phone that has not tapped the
button: the app only draws with the jar's files once they are in its own directory.

## Step 6, item 2: an edit re-meshes one column, not the world

The world's geometry is no longer one flat mass. Every (pass, column) pair owns a *slot*:
a range of the vertex arena with slack, and a range of the index arena, with indices
absolute. C draws one `glDrawElements` per range, in pass order, and after an edit uploads
only the slots that changed (`glBufferSubData`), falling back to a whole upload only when
the arena itself grew because a column outgrew its slack.

Three numbers say whether it worked, and the headless suite checks all of them
(`PASS: 230 checks, 0 failures`):

```
ranges: 27 slots for 9 columns
ranges: 543276 + 12786 + 0 = 556062 indices used of 698529 in the arena
edit 0: 1 columns, 73 units of work, is_edit 1
edit 0: 7 calls, worst call 7.04 ms, worst slice 2.52 ms
edit 1: 2 columns, 145 units of work, is_edit 1
edit 1: 13 calls, worst call 7.13 ms, worst slice 2.51 ms
edit: patched geometry 5753a44b6995c9bd (556062 indices), rebuilt 5753a44b6995c9bd (556062)
```

* an edit does `73` units of work (its column's 72 sections plus the close) or `145` on a
  chunk border, against `649` for the whole world — and the old code re-meshed the world;
* the worst single slice was **2.5 ms**, the worst step call 7.1 ms on this host, against
  the 50 ms an edit is allowed;
* the patched world hashes to the same geometry as a mesh built from scratch, pass by pass
  and index by index, so patching dropped nothing and duplicated nothing.

The same code path re-meshes on the device, and the emulator smoke test now fails if
`edit: re-meshed` reports more than four columns, or a slice of 50 ms or more.

**Also fixed while in here:** the column loop was outside the batch loop, so every column
was meshed three times and two of the meshes were thrown away. The loading screen's five
seconds was one and a half seconds of work; the unit count is `9*72+1` now, not
`3*(9*72+1)`.

## The device, with the jar: item 1 and item 2 on the emulator (run 43833119867, android)

The emulator job pushes the real 26.3 jar and runs the same app the owner would:

```
jar: pushed 41483720 bytes, device says 41483720
jar: /data/local/tmp/umbra-client.jar, 41483720 bytes: 4192 models, 1288 blockstates,
     1214 textures (1 missing) -- the atlas and the models are the jar's
jar: atlas source is the client jar
self-test: atlas tile 749 sampled in 0.2 ms
self-test: atlas 0 of 256 texels differ
SELFTEST PASS (0 bad of 4147200 px + 256 atlas texels, 3505 ms, offscreen, atlas from the jar)
```

and after a break on the ground:

```
player: break -> 1 (broke grass_block at 25 65 23)
player: re-meshing 1 column(s) after edit 1
edit: re-meshed 1 of 9 columns in 149.1 ms over 17 calls
      (worst call 21.0 ms, worst slice 21.0 ms), 3 slot(s) changed
```

One column of nine, 149 ms of work, and no slice over 21 ms on the emulator's software
renderer. The place edit took the incremental path: `edit: uploaded 3 slot(s), 2277.8 KB of
vertices, 284.7 KB of indices` out of a 25 MB mesh.

**What this run also exposed, and what was fixed because of it:**

* The smoke test counted `edit: re-meshed` *after* tapping break, and the edit finished
  within a second: the count was already incremented, so the test waited two minutes for a
  line it had missed. The count is taken before the tap now.
* The first edit after start-up re-uploaded the whole 25 MB mesh, because the initial mesh
  left the "everything moved" flag set. `finish_scene` clears it after its upload.
* The real-world render on a bigger world died with `goose runtime error: index 1 out of
  bounds (length 1)` in `ms_sel_at`: the blockstate selection lives in one shared buffer,
  and the cullface test runs `ms_select` again for every face, so the second rule of a
  multipart state read past the end of a one-rule buffer. The selection is copied out
  before it is walked, in both places that walk it.
* The home screenshot no longer matched `docs/reference/emulator_home.png` (26.68 of 255,
  over the 24 limit). It should not: the reference was a picture of the twelve placeholder
  tiles with three of four columns floating in the air. The reference is now this run's
  home screen -- the jar's grass, dirt, leaves and stone, one island on the ground -- and
  the gate compares against that.

## The real world, after the selection fix (run 43838861645)

The crash is gone and the render is a picture of terrain drawn with the game's own art:

```
jr: coverage 739 permille of the frame (383425 of 518400 px), sky 134975
jr: atlas texels compared with the jar's PNGs: 6144 sampled, 0 differ
jr: PASS - a world drawn with the jar's own models and textures
```

`docs/reference/real_world.png` is re-recorded from that picture. The old one was drawn
while `ms_sel_at` was reading past the end of the selection buffer, so it was a picture of
a renderer that skipped faces; the new one draws every rule of every multipart state.

## Asking the server, when the server will not answer "what is here"

`/data get block` answers only for block entities in this server version, so the first
version of the comparison collected 144 refusals and nothing else. The question is asked
the other way round now -- the game confirms or denies the block Umbra claims:

```
scoreboard players set probe umbra_probe 0
execute if block <x> <y> <z> <name>[<props>] run scoreboard players add probe umbra_probe 1
scoreboard players get probe umbra_probe
```

and the verdict is read from the score, not from the command's reply: `... run say
UMBRA_YES` came back empty even for bedrock at the bottom of the world, and an empty reply
cannot be told from a refusal. Before the sample, the same predicate is asked about a block
that is certainly not there; if that scores 1, the oracle accepts everything and the probe
stops instead of printing a meaningless pass.

## The denials and the 3x gap were one thing: the save was read while it was still growing

Run `43847395025` (commit `e59ea6f`) failed at step 13 with 17 of 168 coordinates denied,
and two numbers in the same run looked like a reader bug: the hook read `529 chunks,
844904 non-air blocks, states 44` while the renderer, on the same save, said `169 chunks,
2634366 non-air blocks`. Both are explained by the run's own evidence, and neither was a
reader fault. The evidence is the run's committed artifact (`cd1fb89`,
`evidence/world/*`), not a re-run:

```
gen-world.txt   worldload: chunks 529, non-air blocks 844904, states 44   <- at 10:19:25
read-real.txt   worldload: chunks 1089, non-air blocks 7351783, states 76 <- after the stop
```

**One: the world moved between the read and the question.** The hook read the save while
the server was still generating it (529 of the eventual 1089 chunks, 44 of 76 states). It
then handed the coordinates to `probe_server_blocks.py`, which *force-loaded* exactly those
chunks - and force-loading completes generation: carvers cut caves, ores and plants are
placed. So the game answered about a finished world while Umbra had read an unfinished one.
The denial pattern says so: 10 of the 17 denials were `stone` at y=54 and 4 more at y=24,
confirmed at those same heights 26 and 28 times, in different columns. That is stone that
became a cave, not a reader that lies about where stone is.

Fixed by ordering, and each half is host-tested:

- `tools/compare_with_server.sh` force-loads the sample area **first**, before anything is
  read, and fails if the server refuses it.
- It then flushes and reads the save repeatedly until **every chunk is `minecraft:full`
  and three consecutive readings agree** in chunk count, block count, state count, total
  region-file bytes *and* the newest mtime. Two agreeing readings were not enough: chunks
  appear in bursts, so a lull can look settled. And agreement alone was not enough either
  - see the next section, where a stalled save agreed with itself six times over while
  528 of its 529 chunks were unfinished.
- It covers the sample area in strips that fit the server's 256-chunk cap on a single
  `forceload add`, and fails if any strip is refused. Two runs taught this. `43855851186`
  showed that the reply (`Too many chunks in the specified area (maximum 256, but
  specified 441)`) was being ignored; `43857378184` showed that the first repair was still
  wrong, because it sliced in *blocks* (`-160 -160 175 95`, which the server counts as 336
  chunks). The count the server caps is the number of chunk columns the box touches, so
  the splits are computed in chunks now: a radius-10 box is 441 chunks and goes as 252 +
  189. Both branches are host-tested against a stub that counts chunks the way the server
  does and refuses anything over 256.
- `tools/probe_server_blocks.py` no longer loads anything itself. The probe is purely a
  question-asker now; loading belongs to the shell, before the read.
- `goose/worldload.goose` counts chunks whose `Status` is not `minecraft:full` and says so
  by name, because that is the condition that made the numbers wrong.

**Two: 169 vs 529 was never the same question.** The renderer's `jr: save` line is a
radius-6 window; the hook printed the *whole save*. The radius argument in
`worldload` only ever governed **detail lines**, not the totals - the `compare: at radius 6`
line was added to prove otherwise and printed the same whole-save totals, which is exactly
what it should have done. `worldload` now prints the windowed totals on its own line
(`detail lines for chunks within N of the origin: C chunks, B non-air blocks`), the
cross-check uses that line, and the CI read after the stop uses radius 10, the same window
the server is asked about (it was 3, which does not even cover the probe's box: x -96..-30,
z 64..130 is chunks -6..-2 by 4..8).

**What that uncovered, and is a real bug:** `demo_is_air` (the renderer's non-air test) did
not treat `minecraft:void_air` as air, while `wl_is_air` (the loader's) always has. Fixed.
On the fixture where the two are now compared directly they agree exactly:

```
worldload: detail lines for chunks within 2 of the origin: 9 chunks, 55625 non-air blocks
jr: save 1 region file(s), 9 chunks, 55625 non-air blocks, 0 read error(s)
```

**A section's palette width is now a gate of its own.** The real save holds 5- and 6-bit
sections, and above four bits a value runs across a 64-bit word. `tools/check_reader_bits.py`
builds a save with 2-, 6-, 20- and 40-entry palettes using the project's independent Anvil
writer, reads it with both the Goose loader and the Python oracle, and requires all 13104
blocks:

```
bits: the oracle PASS: two independent readers agree on every block of all 1 chunks
bits: 13104 blocks expected over palettes of [2, 6, 20, 40] entries, 13104 read
PASS: every block of every palette width was read back, 13104 of 13104
```

`tools/make_test_save.py` was removed: nothing referenced it, and it could not write a save
the loader would read. The types `tools/__pycache__/*.pyc` that had been committed are
untracked and ignored.

While wiring the partial-save gate in, the workflow itself was broken and the run proved
it in the most direct way available: `43855510033` finished in **0 seconds with zero jobs**.
A heredoc at column 0 inside a `run: |` block ends the block scalar, so the file stopped
being YAML and GitHub rejected it before anything started - the world job never ran, and
nothing in the repository could have noticed. The script it held is now
`tools/downgrade_chunk_status.py`, and `tools/check_workflows.py` runs first in the `core`
job: it requires every workflow to parse, forbids a block-scalar body from escaping its
key, and refuses an inline heredoc in a workflow at all. Its own value is checked by
re-running it against the broken file from `4618b10`, where it reports `not valid YAML`.
The step it guards is host-verified in both directions: on a copy of a save with one chunk
downgraded, `original chunks 4, non-air blocks 24777` and `downgraded chunks 4, non-air
blocks 24777` (nothing moved), with `PASS: a partly generated save is named as such`; with
the downgrade skipped it fails with `a partly generated save was not detected`.

### The run that proved the first version of the fix was not enough (43855851186)

The world job ran again on `74108f7` and failed at the new step, which is exactly what that
step is for. Its own evidence (`7d53f9c`, `evidence/world/gen-world.txt`):

```
== forcing the sample area to generate before anything is read
Too many chunks in the specified area (maximum 256, but specified 441)
Saving the game (this may take a moment!)Saved the game
compare: attempt 1: chunks 529, non-air blocks 843609, states 45
compare: attempt 2: chunks 529, non-air blocks 843609, states 45
compare: attempt 3: chunks 529, non-air blocks 843609, states 45
compare: the save is settled - three readings in a row agree: chunks 529, ...
compare: worldload: 528 of 529 chunks are not `minecraft:full` yet: ...
compare: FAIL some chunks in the save are still only partly generated
```

Three things, all now fixed and all host-tested:

1. **The forceload was refused and the script did not notice.** The box is 441 chunks and
   the cap is 256. It is now sent as strips of at most 256 chunks, and a refusal fails the
   step: `compare: FAIL forceload -160 -160 175 95 was refused: Too many chunks ...`.
2. **"The file stopped changing" is not the same as "the world is finished."** The save had
   stalled - identical totals three times - with 528 of 529 chunks still generating. The
   loop now also requires every chunk to be `minecraft:full`, and refuses otherwise:
   `FAIL the save never reached a state where every chunk was finished`.
3. **A save that is not finished is now refused by `worldload` itself**, not just by the
   shell around it: `FAIL 528 of 529 chunks are finished; pass --incomplete-ok to read a
   save that is still being written`. `--incomplete-ok` exists so the settling loop can
   measure an unfinished save; nothing else uses it.

The same run shows the rest of the gate is healthy on the settled save, read after the
stop: `worldload: chunks 1089, non-air blocks 7351783, states 76, read errors 0`,
`detail records that agree: 1146457 of 1146457 (100.00%)`, `PASS: two independent readers
agree on every block of all 1089 chunks`, and the renderer `169 chunks, 2634366 non-air
blocks, 0 read error(s)`. So the two-readers half of gate 6b is solid; only the
server-comparison half was comparing against a world that had moved.

### The third run: the refusal was right but too wide (43858549623)

`c4224a2` got further than anything before it — the strips were accepted
(`forceload -160 -160 175 31 (21 x 12 chunks) -> Marked 252 chunks`, then `189`) and the
save held **794 chunks and 19,953,328 non-air blocks** — and then the new rule refused it:

```
compare: attempt 6: chunks 794, non-air blocks 19954001, states 141 - not finished (169 of 794 chunks are not)
compare: FAIL the save never reached a state where every chunk was finished
compare: worldload: 169 of 794 chunks are not `minecraft:full` yet
```

The 169 are not in the sample area. They are chunks the *first* forceload strip reached
through: that strip covers 21 x 12 chunks for a 21 x 21 box, so nine of its rows run
beyond the window, and a chunk that is force-loaded part-way through generation is left
partly generated for as long as it stays loaded. A chunk 11 rows away cannot make the game
deny a claim about a block inside the window, so refusing the whole world for it was the
wrong rule.

The refusal is now scoped to the detail window, which is the only set of chunks that can
produce a denial:

```
worldload: 1 of 4 chunks are not `minecraft:full` yet (1 of them within 2 of the origin)
worldload: FAIL 1 chunks in the detail window are still being generated, so nothing read
           from them can be trusted; pass --incomplete-ok to read a save that is still
           being written
```

and a partial chunk *outside* the window no longer blocks a read (host-tested: the same
save at radius 1 reports `1 of 1 chunks are not ... (0 of them within 1 of the origin)` and
does not refuse on that account).

### The fourth run: the loop was still waiting on chunks it could never ask about (43859688264)

The scoping in `worldload` worked — `169 of 794 chunks are not ... (0 of them within 10 of
the origin)` — but the shell loop around it still refused on the whole-save count, so the
run failed with the same message plus `0 of them within 10 of the origin`, which said
plainly that it was waiting for something irrelevant. The loop now waits only when a chunk
**inside the window** is unfinished, which is the only condition that can produce a denial:

```
worldload: 1 of 4 chunks are not ... (1 of them within 2 of the origin)   -> wait
worldload: 169 of 794 chunks are not ... (0 of them within 10 ...)       -> proceed
```

Both are checked by calling the loop's own test on the exact line each run produced.

### The fifth run: the fingerprint measured the wrong thing (43861773812)

Every attempt now reported `the window is finished`, and the loop still failed, because the
fingerprint was the whole save's block total, which climbed on every attempt
(`19948219`, `19950832`, `19951643`, `19951951`, `19952144`) as chunks outside the window
finished generating. Only the window is compared with the game, so only the window has to
hold still:

```
compare: attempt 1: 1 chunks, 6273 non-air blocks, the window is finished
compare: attempt 2: 1 chunks, 6273 non-air blocks, the window is finished
compare: attempt 3: 1 chunks, 6273 non-air blocks, the window is finished
compare: the save is settled - three readings in a row agree
probe: 180 confirmed, 0 denied, 0 errors
```

That output is from the exact shape of the failing run, built here: a save that gains a
distant chunk every second while a radius-0 window stays byte-for-byte the same. Before
this change that shape failed; now it settles and every one of the 180 coordinates the
probe asked about is confirmed.

### The sixth run: the comparison passed, and the gate step above it was wrong (43863228323)

This is the first run in which the server agreed with Umbra about everything it was asked:

```
compare: attempt 1: 441 chunks, 14143463 non-air blocks, the window is finished
compare: attempt 6: 441 chunks, 14146918 non-air blocks, the window is finished
compare: the save is settled - three readings in a row agree: 441 chunks, 14146918 ...
worldload: PASS - every chunk in the save was read
compare: at radius 6 worldload: detail lines ... 169 chunks, 5520581 non-air blocks
probe: the dump has 14146918 blocks over 336 x and 336 z lines; asking about 150 of them
probe: control: minecraft:stone at -160 -64 -160 scores 0
probe: 150 confirmed, 0 denied, 0 errors
compare: the server answered every claim
```

`150 confirmed, 0 denied` is gate 6b's second half actually met for the first time: the game
confirms Umbra's block *and its properties* at every coordinate sampled, with the control
coordinate still scoring 0 so the oracle is known to be able to say no.

The job still failed, at step 12 - my own new step, above the comparison. It downgraded the
*first chunk of the first region file*, which is the corner of the region and outside the
detail window, so `worldload` correctly declined to refuse anything. `tools/downgrade_chunk_status.py`
now takes `cx cz` and the step names chunk 0,0, which a window centred on the origin always
contains. That tool also grew two real fixes found by testing it: every genuine earlier
status (`minecraft:carvers` 17, `minecraft:biomes` 16) is *longer* than `minecraft:full`
(14), so in-place padding could not work, and the record is now rewritten whole with the
header repointed when it does not fit. Both branches are exercised: `in place` on a normal
save (all 9 chunks and 55625 blocks still read afterwards) and `moved to sector 11 (1
sectors freed, 2 used)` on one trimmed to a single sector, again with every chunk intact.

### The seventh run: everything before the render is green, and the reference picture was wrong (43864624600)

```
10 success Generate a real world with the real server
11 success The shape of one real chunk
12 success A save read while it is still being generated is refused, not compared
13 success Read the real world twice and compare it block by block
14 failure Draw the real world with the game's own models and textures
```

Step 13 is the two-readers half of gate 6b, and it is green on a bigger world than ever
before: `worldload: chunks 2209, non-air blocks 26568648, states 141`,
`PASS: two independent readers agree on every block of all 2209 chunks`.

Step 14 failed, and not in the renderer. The render itself says
`jr: PASS - a world drawn with the jar's own models and textures`, `169 chunks, 5519837
non-air blocks`, `0 with no model`, `missing-tile magenta 0`, `6144 texels compared with the
jar's PNGs, 0 differ`. What failed was `check_world_shot.py` against the committed
reference: `mean absolute difference 29.11 (limit 12.0)`.

**The reference was a picture of a world that had not finished generating.** It was recorded
by run `43831301517`, whose own log says `jr: save 4 region file(s), 156 chunks, 503215
non-air blocks` — 3226 per chunk, against 32662 in this run and 32079 in the loader's own
radius-10 count of the settled save. A real 26.3 chunk holds about 32k non-air blocks, so
the reference was drawn from a world holding a tenth of that: the same half-generated save
that made run `43847395025` report 529 chunks where the settled file holds 1089. The
picture's own colour counts agree — `pale` (sand and stone) 193 -> 39058, `green`
24553 -> 35963 — and the two frames show the same tree, the same hills and the same camera,
one of them with no grass on it.

`docs/reference/real_world.png` is re-recorded from this run's picture, by the rule this
project uses: a reference is replaced only when the run's own numbers show the new picture
is the real state. `0.00 of 255` against itself, and the two-readers gate above it passed on
the same save.

**A stale-evidence bug found by reading this run's artifacts.** `evidence/world/server-blocks.txt`
and `server-compare.txt` in this run's evidence commit are from the *previous* run: the
probe never ran (the comparison was refused before asking), the "Hold Umbra's blocks to the
answers" step was therefore skipped, and a skipped step does not clean up - so
`Commit the numbers` published an older run's 17 denials as if they were this run's. That
step is now `if: always()`, deletes the evidence first, and writes `SKIPPED: no server
verdict in this run` when there is nothing fresh. A gate that did not run must not publish
another run's verdict.

### The eighth run: green, and that was the problem (43867075771)

Every one of the 17 steps reported `success`. Underneath, the comparison it is supposed to
guarantee had been refused:

```
compare: attempt 6: 441 chunks, 14144846 non-air blocks, the window is finished
compare: FAIL the save never reached a state where the sample area was
compare:      finished and had stopped changing
evidence/world/server-compare.txt: SKIPPED: no server verdict in this run
```

Two things were wrong, and only one of them was timing.

**The job could not go red.** `gen_server_world.sh` treats a failed comparison as a warning
("WARNING: the server comparison did not pass"), and my stale-evidence guard then turned the
skipped collection step into a clean exit. So a refused comparison produced a green run -
which is worse than a red one, because it says a gate passed when it never ran. That step
now greps its own log and fails on `compare: FAIL` or on a missing
`compare: the server answered every claim`, and the collection step fails too when there is
no fresh `server-blocks.txt` instead of writing `SKIPPED` and exiting 0.

**And it really was one reading short.** The window converges rather than stopping dead -
`+2365, +803, +283, +156, +0` - and six attempts ended exactly one confirmation short. The
loop allows ten now. Replaying this run's own six measurements through the loop's rule
settles at attempt 7: `14144846` three times.

### Green with the gate actually met (43868464871, evidence commit `dc2e218`)

Every step success, and this time the evidence underneath it is from that run:

```
compare: attempt 4: 441 chunks, 14144660 non-air blocks, the window is finished
compare: attempt 6: 441 chunks, 14144660 non-air blocks, the window is finished
compare: the save is settled - three readings in a row agree: 441 chunks, 14144660
probe: 150 confirmed, 0 denied, 0 errors
compare: the server answered every claim
```

```
step 12  A save read while it is still being generated is refused  success  (0 FAIL lines)
step 13  Two independent readers:
         worldload: chunks 2209, non-air blocks 26568999, states 141
         oracle:    chunks 2209, non-air blocks 26568999, states 141
         chunks that agree: 2209 of 2209 (100.00%)
         blocks in agreeing chunks: 26568999 of 26568999 (100.00%)
         PASS: two independent readers agree on every block of all 2209 chunks
step 14  jr: save 4 region file(s), 169 chunks, 5520145 non-air blocks, 0 read error(s)
         250966828 blocks drawn from a model, 0 with no model
         6144 atlas texels compared with the jar's PNGs, 0 differ
         jr: PASS - a world drawn with the jar's own models and textures
         mean absolute difference from the reference: 0.98 of 255 -> PASS
step 15  server blocks: 150 coordinates asked, 150 confirmed, 0 denied
         PASS: the server confirms Umbra's block and properties at all 150
```

**Gate 6b is met, with the caveat the brief names and this project has always recorded:**
the client cannot run in CI, so the second half is the game's own verdict on Umbra's blocks
over RCON, not a rendered client. Two things make that verdict worth something and both are
in the log: the control coordinate scores 0, so the oracle is known to be able to say no,
and the comparison only runs on a save that three consecutive readings show has stopped
changing with every chunk in the sample area finished. What is
host-verified here is the ordering (a stub RCON server shows `forceload` arriving before
any `save-all`), the settling loop in both directions (a still save settles after three
readings and the probe gets 153 of 153 confirmed; a save that grew every second failed with
"never stopped changing"), and the partial-status warning (`1 of 4 chunks are not
... minecraft:full ... yet`) on a copy of a save with one chunk's status downgraded, with
all four chunks still read).
