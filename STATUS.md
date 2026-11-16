# Status

Updated 2026-11-15 (stage 3, step 3: the jar draws the world). This file is the contract between sessions: if the work is
interrupted, a single "continue" resumes from **Next steps** with nothing lost.

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

**State: implemented and host-verified on the synthetic world, CI run pending.** No real
world has been read yet, so there is no real-world match rate in this file and none may
be claimed.

## Parity table (what is and is not the same as the game)

| Thing | State | Proof |
|---|---|---|
| Anvil regions, NBT, PNG, zip, inflate | tested | `region 237`, `nbt 196`, `png 153`, `zip 137`, `inflate 97` checks |
| Block models: every model in the jar parses | yes | `4192 block models parsed, 0 refused`, `1205 elements, 4300 faces` (jar 26.3, CI) |
| Models are drawn from their geometry | every block, from the jar | `blocks drawn from a model 1498125, faces 454261` over the synthetic jar, host-verified; the demo slab's 6 faces, `y+0.5` top and culled bottom are still host-tested (`mesh 354`) |
| Binding the jar's blockstates to models at load | yes, host-verified | `1731 rules linked to a model`, `0 refused` (synthetic jar); the real jar runs in the `jar` workflow (D-042) |
| Textures from the jar | yes, host-verified | 469 textures packed into a 512x512 atlas, `6144` texels compared with the jar's PNGs, `0 differ`; the phone still ships the 12 placeholder tiles (D-039) |
| A world drawn from the jar's models and textures | CI-verified picture | `goose/jrender.goose` -> `evidence/jar/world.png`, compared with its reference by `tools/check_world_shot.py` |
| A body you can walk with | yes | 24 host checks, and the device run above |
| Water, ladders, sneaking, swimming, mobs, survival, multiplayer | **no** | not implemented |
| Reading a world from a real save | implemented, synthetic-verified | two independent readers, `24673 of 24673` blocks, 100.00%; the real server's save runs in the `world` workflow |
| Rendered world matches the real client | **not measured** | gate 6b second half: nothing compares two renders yet |
