# Status

Updated 2026-11-15. This file is the contract between sessions: if the work is
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

There is still **no download link** at the time of writing (the release workflow
exists and is described below; no tag has been pushed yet), no world-parity
numbers, and no ARM execution: the arm64 APK is built but never run, and the new
`core-tests-arm64` job has not produced a result. Umbra is not Minecraft, and the
parity table is empty.

| Gate | State | Evidence |
|---|---|---|
| 1. CI builds from a clean checkout | PASSING | run `43671700216`: `Build APK (arm64 + x86_64)` job `completed success` |
| 2. APK checks (unzip/aapt2/apksigner/lib per ABI) | PASSING | same run, step `Gate 2 - APK integrity` success; annotations: `package: name='org.umbra.client' versionCode='1' versionName='0.1.0' compileSdkVersion='35'`, `native-code: 'arm64-v8a' 'x86_64'`, `apksigner … v1 scheme: false` (v2/v3 cover minSdk 24) |
| 3. Emulator smoke + fresh screenshot | PASSING (once caught a blank screen) | run `43671700216`: every step of `Emulator smoke test + screenshot` is `success`, including `Screenshot gate (fresh, non-blank, similar to the reference)`. That run's own capture differs from the reference byte for byte (`evidence/ci/shot1.png` sha256 `26e81928eb09aea9`, reference `ea2a1be5…`) and still measures `mean absolute difference 0.00 (of 255)` |
| 4. Core tests on x86_64 | PASSING | run `43674038711`, step `Core test suite (formats, mesher)`: `PASS mem (19) inflate (97) zip (137) png (153) nbt (196) region (237) json (302) mesh (340)`, `all modules passed` (`evidence/ci/core-tests.txt`) |
| 4. Core tests on arm64 | JOB WRITTEN, FIRST RUN NOT READ | `.github/workflows/core.yml` gained `core-tests-arm64` on `ubuntu-24.04-arm`; the job parses (PyYAML) but has not run yet, so it is not a result. The APK's own arm64 `.so` is still compiled and never executed -- an arm64 runner running the *host* suite does not change that |
| 5. PC builds (Windows x64, Linux x64) + headless self-test | PASSING | run `43674038711`: `Linux x64 build + headless self-test` and `Windows x64 build + headless self-test` both `completed success`; the Windows binary ran under MSYS2 UCRT64 on `windows-latest`, not under Wine. `evidence/ci/pc-linux-x64.txt` and `pc-windows-x64.txt` both end `PASS: 19 checks, 0 failures`; sha256 `1a1c76665f5a013b…` (linux) and `0190ba968e53b943…` (windows) |
| 6a. The jar's model data is self-consistent | PASSING | run `43680833198`: `PASS: every model a blockstate can render resolves through its chain (2603 models, 25048 faces, 3964 textures)`; jar `26.3`, 41 483 720 bytes, sha1 `e877b6a07acd633f…`, verified against Mojang's manifest at test time (`evidence/jar/pin.txt`, `evidence/jar/jarcheck.txt`) |
| 6b. World parity against the real client | NOT DONE | nothing renders the jar's models yet; the mesher still uses a demo world |
| 7. Release assets verified by re-download | WORKFLOW WRITTEN, NO RELEASE YET | `.github/workflows/release.yml`: builds the APK and both PC binaries from the tag, runs the Windows `.exe` under wine, publishes a pre-release, then re-downloads **every** asset from its public URL, requires HTTP 200 and a matching SHA-256, and commits `RELEASE_VERIFY.txt` with the run URL. Until a tag exists and that file is committed, gate 7 is open |

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

1. **Publish `v0.3.0-pre`** (gate 7): tag the commit that carries time-sliced
   meshing, insets and the four-line benchmark, let `.github/workflows/release.yml`
   build the APK and both PC binaries from the tag, publish the pre-release, and
   record the committed `RELEASE_VERIFY.txt` here. Report URL, size, SHA-256,
   install steps and `docs/PHONE_TEST.md`.
2. **Close gate 4 on ARM**: read the first result of `core-tests-arm64`
   (`ubuntu-24.04-arm`) and say plainly that the Android arm64 `.so` is still
   compile-only -- no CI job executes it.
3. **Atlas and block models** from the jar: blockstates + models + a texture atlas
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

## Blockers

None that stop work. This session's sandbox has no JDK, Android SDK/NDK, adb,
GPU or KVM, so the APK, the emulator and the phone-facing checks can only run in
GitHub Actions; that is where gates 2, 3 and 5 run, and where their evidence is
produced.
