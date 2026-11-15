# Known issues

Anything here is a defect we know about. If it is not here and it is broken, it
is a bug we have not found yet. Nothing in this file is fixed by claiming it is.

## Stage 2 (Android shell) — open at the time of writing

* **The phone has run `0.3.1`, and `0.3.2` has not.** The owner's Mali-G57 MC2 ran
  `0.3.1` and produced the three numbers this release is built on: `GPU self-test
  FAIL: 2458665 bad of 4950720 px`, a previous run that ended at `SELF-TEST: BEGIN
  (2292x1080)`, and a benchmark of 59 FPS. The fixes for all three are in `0.3.2`
  and are **unconfirmed on hardware** -- confirming them is what the owner's next
  run is for. The CI emulator (x86_64, SwiftShader) frame times, about 60-90 ms,
  are a software rasteriser's numbers and say nothing about a phone.
* **The self-test has never taken its fallback path on a device.** The new state
  machine has run on the CI emulator, which provides a complete framebuffer object
  (RGBA8 + depth). A driver that refuses depth 24 falls back to depth 16 and then
  to reading the window; that third path exists for a reason but no device has
  taken it.
* **Meshing is sliced, not threaded.** It used to be one 5.3 s call
  (`demo world built in 2.7 ms, meshed in 5304.1 ms`); it is now stepped from the
  frame loop at `UMBRA_MESH_BUDGET_MS 6`, and one step can overrun by a single mesh
  unit (measured `worst call 10.21 ms` on the desktop host). Meshing still runs on
  the thread that owns the window: the window keeps drawing a `LOADING WORLD nn%`
  screen instead of freezing, but initial start-up is not faster. Moving it to a
  worker thread is Stage 3.
* **The 1% low is a CPU frame-time statistic**, measured between `glFinish`-bounded
  frame boundaries in `umbra_app.c`. GPU time comes from
  `EXT_disjoint_timer_query` when the driver has it, and the two are reported on
  separate lines; neither is a present-to-present number, and on a phone with a
  compositor all three differ.
* **"Uncapped requested" is not "uncapped".** The benchmark calls `eglSwapInterval(0)`
  and logs whether EGL accepted it, but Android's compositor still throttles to the
  display's refresh rate in many configurations. The benchmark line says which of
  `uncapped requested`, `refused` or `capped by the platform` happened; it never
  presents the 59 FPS of `0.3.1` as a GPU limit when it was the 60 Hz cap.
* **The overlay is excluded from the comparison, by overlap.** Every pixel any part
  of the panel or a button touches is skipped, and the count is logged. On the
  fallback path (no framebuffer object) that is a large fraction of a landscape
  phone screen -- about half of 2412x1080, because the panel is a quarter of the
  height. On the offscreen path nothing is skipped.
* **The 30 s self-test watchdog can end a merely slow test.** It reports
  `watchdog: 30 s in compare pattern` instead of a verdict: honest, but a very slow
  driver then gets no pixel verdict at all.
* **The EGL surface can come up before the window has buffers.** It did on run
  `43687356640` (`EGL up: 1x1`) and the whole run drew a blank screen. The size is
  now re-read every frame (D-031) and the smoke test fails on a surface narrower
  than 320 px, but the underlying race belongs to the platform: `APP_CMD_INIT_WINDOW`
  can arrive with a window whose buffers are not sized yet.
* **Insets are read but only tested on an emulator with no insets.** The JNI code
  asks for `getRootWindowInsets()` and the display density, and the HUD lays itself
  out from them, but the CI emulator reports zero insets, so a real status bar,
  gesture bar or display cutout has never moved a button. The owner's phone is the
  first real test.
* **The world in the screenshot is a demo world, not a Minecraft world.** It is
  generated in Goose (stone, dirt, grass, water, trees, plants), with no textures
  and no block models: the whole surface is untextured, so grass reads as grey.
  Atlas, blockstates and models from the jar are Stage 3 work.
* **Back-face culling is off** (`glDisable(GL_CULL_FACE)` in `umbra_app_init`).
  The mesher's winding is unit-tested, but the cube and HUD geometry share the
  state and turning it on has not been verified yet.
* **A pause rebuilds the app.** `APP_CMD_TERM_WINDOW` frees EGL and the app is
  re-initialised on return (DECISIONS.md D-017), which re-meshes the world. A
  resume therefore costs the same 4.6 s as a cold start.
* **The release key is public** (`ci/umbra-release.p12`, password in the build
  file, DECISIONS.md D-014). Builds are consistently signed; they are not
  authenticated. Anyone can sign an APK that Android will accept as an update.

## Not implemented yet (by stage)

* **APK builds are not byte-reproducible.** Two builds from the same commit differ
  (released `312bd4ba…`, emulator-tested `2163f797…`, both 214723 bytes), so the
  exact bytes in the release were downloaded back and hashed but were never
  installed on a device. Only the owner's phone has done that.
* **The released Windows `.exe` is verified under wine, not on Windows.** The `pc`
  workflow runs a natively built `.exe` on `windows-latest`; the release job runs
  the shipped one under wine because no Windows machine is available to it.
* **The published builds are pre-releases, and the only one that has ever run on a
  phone is `0.3.1`.** `v0.3.0-pre` and `v0.3.1-pre` stay published; every asset of
  both was downloaded again and hashed. Nothing published has been installed by
  anyone but the owner.
* **No world from the real game has been opened.** No parity numbers exist. Umbra
  is not Minecraft and the parity table is empty.
* **No Umbmod loader, no shader pipeline, no multiplayer.** Stages 6-9 are not
  started; UMBMOD_SPEC.md and SHADER_COMPATIBILITY.md do not exist yet.

## Format limits found while testing

* **LZ4-compressed regions** (compression type 4) are refused with a clear
  error. Vanilla writes zlib, so this only affects some modded servers.
* **Adam7-interlaced PNGs** are refused. Vanilla textures are not interlaced.
* **Zip64** is read for entry sizes but the 64-bit end-of-central-directory
  record is not handled; jars over 4 GiB are not supported.
* **Modified UTF-8** in NBT strings is passed through as bytes, not decoded. No
  Mojang string in a world file needs it.
* **`zlib_store` does not compress.** Regions written by Umbra are larger than
  the game's, and block-sized chunk records may spill into more sectors.
* **Chunk formats before the current one** are read only where the layout is the
  same; pre-1.16 packing is detected by length but not tested against a real
  old world.

## Test limits

* The arm64 test runner does not exist, so **nothing has been executed on ARM**.
* The benchmark numbers quoted so far come from the CPU-only headless build on
  the sandbox machine (`e2b.local`, x86_64, 2 cores) and from SwiftShader on the
  CI emulator. Neither is a phone.
* The screenshot gate compares a fresh capture with a committed reference by
  similarity (mean absolute difference over a 16×16 signature, MAD ≤ 24) and
  rejects identical captures and blank frames. It cannot tell a HUD that is
  correct from one that is merely similar; a human looks at the committed
  screenshot for that.
* The GPU self-test proves the GLES pipeline used by the shaders it runs
  (fullscreen pattern, textured/coloured geometry, depth). It does not prove the
  world renderer's state at every path, and it is not a substitute for looking at
  a phone's screen. The `0.3.1` failure is the proof: the test linked, drew and
  compared, and its own shader was wrong -- `int` was mediump. A desktop driver
  defaults `int` to highp and would never reproduce it, which is why the source
  check in `tools/check_c.sh` exists.

## The jar work stops at the model data

The jar job proves that 26.3's blockstates and models resolve: 2603 used models,
25 048 faces, 3964 textures, 0 problems. It says nothing about pixels yet —
nothing in the client reads those models, packs an atlas, or draws them. The
mesher still builds its demo world out of single-colour cubes, so the home screen
shows no textures at all. Until a world is drawn from the jar's own models, there
are no parity numbers to publish.

The checker also does not read `data/` (loot tables, worldgen, recipes), the asset
index's 487 MB of objects, block `states` beyond `variants`/`multipart`, or
`item_components`. Only what the renderer will need first.

### The emulator is not the phone

- The emulator reports density bucket 420 (scale 2.62) where the owner's phone is
  3.5, so the overlay's scale and the free band on the phone are the host-test
  numbers, not the emulator's. `platform/pc/headless_main.c` checks the phone's
  numbers; nothing but the phone can prove the result.
- The emulator has no display cutout. The cutout branch of `fill_insets()` has
  never run on a device that has one; it is covered by a host test with a 112 px
  left inset and by the code path alone.
- `debug.umbra.insets` is a system property, so CI can simulate a status bar the
  emulator does not have. On a real phone `adb shell setprop` needs a PC, which the
  owner does not have: the property exists for CI and for a developer's device.
- The emulator's SwiftShader reports 10-20 fps for a 370k-vertex scene where the
  owner's Mali-G57 reported 59 fps. Frame-rate numbers from CI mean nothing about
  the phone; they are there to catch a regression, not to predict one.
