# Known issues

Anything here is a defect we know about. If it is not here and it is broken, it
is a bug we have not found yet. Nothing in this file is fixed by claiming it is.

## Stage 2 (Android shell) — open at the time of writing

* **Nothing has run on a phone GPU.** The only device that has run the app is the
  CI emulator, x86_64, with SwiftShader as the GLES 3.0 implementation. Frame
  times measured there (about 60-90 ms per frame) are a software rasteriser's
  numbers and say nothing about a phone. The `highp` fragment path is reported
  (`fragment highp 127^23`) but has not been executed on real hardware.
* **Nothing has run on ARM.** The arm64 slice compiles and is inside the APK, and
  no arm64 device has executed it.
* **Meshing the demo world takes 4.6 s on the emulator** (`demo world built in
  27.4 ms, meshed in 4624.2 ms`). It runs on the thread that owns the window, so
  the first frame is 4.6 s after launch. The mesher is not optimised and not
  threaded; both are Stage 3 work.
* **The HUD does not know the system insets.** `umbra_app.insets` is never
  filled on Android, so the three buttons can sit under the navigation bar on a
  phone. On the emulator they land inside the screen (`hud: button 0 at 8,946 on
  1920x1080`), which is not the same thing as being right on a phone.
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

* **No download link and no PC release binaries.** The Linux x64 headless build
  exists and passes locally; the Windows x64 build and any published asset do not.
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
  a phone's screen.
