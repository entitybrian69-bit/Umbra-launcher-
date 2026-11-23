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
* **The world in the screenshot is a demo world with placeholder art.** It is
  generated in Goose (stone, dirt, grass, water, trees, plants) and textured
  through the real atlas pipeline, but the twelve tiles are generated in
  `core/textures.goose`, not taken from the jar (D-039: no Mojang assets are
  shipped). The jar's own textures and models are exercised in CI only. Block
  models from the jar (`elements`, per-face UVs, rotations) are not used yet: the
  mesher draws whole cubes from a name-keyed table.
* **Back-face culling is on for the opaque world pass only.** The mesher's
  winding is checked in the host suite (every triangle's cross product against its
  normal, 0 flipped), and cross plants stay two-sided because they are single
  quads; the HUD and the self-test cube are not culled.
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

## Block models: one at a time, and not the jar's

`core/models.goose` parses one model into module globals, and the mesher draws the
geometry of exactly one bound block from it (D-040). The demo world uses that for a
plank slab, so the path is real and tested, but every *other* block still draws as a
whole cube. A block that has a model in the jar and is not bound draws wrong in a way
a screenshot can show — a slab as a full block. Binding blockstate → model → parents
at load time is the next stage, and it needs a per-block model cache.

The textures are ours, not Mojang's (D-039): twelve procedural tiles. The jar's
textures resolve in CI (`3964 textures` in the jarcheck) but nothing loads them into
the atlas, because the jar is never in the repository or the APK.

## The player: one body, no swimming, no full-block auto-step

The body is 0.6 x 1.8 and collides with full blocks and the model's slabs. It does
not swim (water is not solid, so it walks along the bottom of a pond), does not climb
ladders, cannot sneak, and stops at a full-block rise rather than stepping up it. One
finger: drag to look, rest 400 ms to walk, tap to jump. Two-finger movement, and any
on-screen stick, are not in yet.

Input coordinates are in the display's *current* orientation, which cost a CI run: a
tap that landed in one run produced nothing in the next, because the activity is
landscape-locked and the emulator had rotated. `tools/emulator_smoke.sh` now asks the
window manager for the display it has and retries the other orientation.

## The emulator's 20 fps is a software rasterizer

`bench: 1207 frames avg 49.77 ms (20 fps)` on the CI emulator is SwiftShader. It is
not a phone number and it is not a regression: the same run reports `vsync: uncapped
requested` and no GPU timer query (`check: gpu timer query none (not available)`), so
on the emulator there is no GPU time to report separately from frame time.

## Release notes: the block that ships with every pre-release

The release workflow copies the section below into the GitHub release body, so
that what a build is known to get wrong travels with the build. `sed` reads it
from this file, which is why the heading is exactly that phrase.

### 0.3.10

* **The budget is now measured in fragments, and that number passes.** The
  gate is `cost_test`: a world built block for block, meshed, drawn on the CPU
  rasteriser, with every number a count rather than a clock. On this build it
  reports `1896 quads, 3792 triangles`, and the same frame in the mesher's emit
  order against nearest-first: **62017 shaded fragments over 30011 distinct
  pixels (2066 permille) becomes 30088 (1002 permille)** -- the same pixels,
  half the shading work. Frame times remain below as information; they are not
  what passes or fails.
* **The frame budget is red on the CI emulator, and it is not noise.** The
  full-size walk (`stream-fullsize`, radius 4, 81 columns resident) reports
  `61 frames over 50 ms`, `avg 39.9 ms`; the cull comparison reports `49 over`
  with the cull on. The pass split, measured honestly with a `glFinish` per pass
  in `stream-where`, is the **opaque** pass every time: `opaque 31.3-45.3 ms,
  cutout 0.5-11.4`. A previous reading said `cutout 38.7`, which was enqueue
  time and would have pointed the work at foliage. This is SwiftShader on an
  x86_64 emulator: it says nothing about a phone GPU, and it is the only
  renderer this project can measure in CI. It is recorded as red rather than
  adjusted, and 0.3.9 did not draw a frame at all -- see the gallery note.
* **The gallery is a real picture for the first time.** Every earlier attempt
  produced a PNG that was 99.8% the clear colour, because the mesh shader
  subtracted a second origin (the player's own position in first person) from
  every vertex while the view matrix stayed in world space. The frame was drawn,
  fogged to the sky colour, and indistinguishable from an empty one. This build
  draws 2905 distinct colours with no single colour over 60%. The gallery is at
  `docs/gallery/` in the repository and on the Pages site.
* **Meshing is still sliced, not threaded** (see Stage 2 above): start-up shows a
  `LOADING WORLD nn%` screen instead of freezing, and moving it to a worker
  thread is Stage 5.
* **The body walks, swims, edits and falls; it does not have an inventory.** The
  hotbar and the touch inventory are not in this build.
* **A world can only be opened from the app's own files directory**; importing
  the owner's own world through the system file picker is not in this build.

## 
