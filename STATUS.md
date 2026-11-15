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

There is still **no download link**, no PC release binary, and no parity numbers.
Umbra is not Minecraft, and the parity table is empty.

| Gate | State | Evidence |
|---|---|---|
| 1. CI builds from a clean checkout | PASSING | run `43670787000`: `Build APK (arm64 + x86_64)` job `completed success` |
| 2. APK checks (unzip/aapt2/apksigner/lib per ABI) | PASSING | same run, step `Gate 2 - APK integrity` success; annotations: `package: name='org.umbra.client' versionCode='1' versionName='0.1.0' compileSdkVersion='35'`, `native-code: 'arm64-v8a' 'x86_64'`, `apksigner … v1 scheme: false` (v2/v3 cover minSdk 24), `sha256 172983ea…` |
| 3. Emulator smoke + fresh screenshot | PASSING the smoke test; reference committed 2026-11-15 | run `43670787000` (`evidence/ci/summary.txt`): install, launch, `EGL up: 1920x1080`, self-test `2073600 pixels checked, 0 mismatched`, tap accepted, 60 s soak survived, no FATAL EXCEPTION; screenshots committed as `docs/reference/emulator_home.png` and `emulator_selftest.png` |
| 4. Core tests on x86_64 | PASSING locally | `PASS mem (19)`, `inflate (97)`, `zip (137)`, `png (153)`, `nbt (196)`, `region (237)`, `mesh (275)` |
| 4. Core tests on arm64 | NOT DONE | no ARM runner yet |
| 5. PC builds (Windows x64, Linux x64) + headless self-test | Linux x64 local PASS; Windows and CI NOT DONE | `PASS: 19 checks, 0 failures` (below) |
| 6. Parity tests against the real game | NOT DONE | no jar has been downloaded yet |
| 7. Release assets verified by re-download | NOT DONE | — |

## Verified results (command output, not claims)

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

### The PC headless host (`build/pc/umbra_headless`, rebuilt 2026-11-15)

```
umbra headless self-test
core version: 0.1.0-stage1
mesh: 17783424 vertex bytes, 2222928 index bytes
mesh checks: 0 bad indices, 0 bad normals, 0 positions out of bounds
batches: 542910 + 12822 + 0 = 555732 of 555732 indices
bench: 1000 frames avg 16.0 ms (62 fps) 1% low 16.0 ms median 16.0 ms worst 16.0 ms | headless | Android none
PASS: 19 checks, 0 failures
```

The 19 checks cover the mesh invariants, the format round trips, the benchmark
arithmetic, the self-test's expected pattern over a whole 64x48 screen, and three
checks that the cube verdict actually rejects wrong pixels — "test the tests".

The machine is `e2b.local`: x86_64, 2 cores, 3 GB, no GPU. 62 fps here is a
CPU-side number — the headless host runs a fixed 16 ms step with no GPU work — and
says nothing about a phone GPU.

### The Goose core, on this machine (gcc 12.2.0, Goose v2026.4 `6c1fbc78`)

```
PASS mem (19 checks)
PASS inflate (97 checks)
PASS zip (137 checks)
PASS png (153 checks)
PASS nbt (196 checks)
PASS region (237 checks)
PASS mesh (275 checks)
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

### The emulator (CI, run 43670787000)

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
`docs/reference/emulator_selftest.png` (after the GPU self-test). Meshing takes
4.6 s on the emulator's CPU — the slowest thing in the start-up path, listed in
KNOWN_ISSUES.md.

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

1. Prove gate 3 end to end: the run after the reference was committed must pass
   the screenshot gate against it (the reference was chosen by looking at the
   capture, not by blessing whatever the run produced).
2. Feed the real block models and textures from the pinned jar into the mesher
   (atlas, blockstates, models) and replace the demo world in the app.
3. Move meshing off the window thread and make it faster: 4.6 s to mesh 370k
   vertices on the emulator is the dominant start-up cost.
4. PC: Windows x64 cross-build in CI plus a Linux release binary, both gated by
   the headless self-test; publish SHA256SUMS.
5. Stage 3 world gates against the official server jar (downloaded at test time,
   never committed), then fill in the parity table with measured match rates.

## Blockers

None that stop work. This session's sandbox has no JDK, Android SDK/NDK, adb,
GPU or KVM, so the APK, the emulator and the phone-facing checks can only run in
GitHub Actions; that is where gates 2, 3 and 5 run, and where their evidence is
produced.
