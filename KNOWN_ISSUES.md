# Known issues

Anything here is a defect we know about. If it is not here and it is broken, it
is a bug we have not found yet. Nothing in this file is fixed by claiming it is.

## Not implemented yet (by stage)

* **No APK, no PC binary, no download link.** The Android and PC shells are not
  built. Gates 2, 3, 5 and 7 in the brief have not run.
* **No renderer.** No GPU code has executed. Everything visual (atlas, mesher,
  block models, shaders) is still ahead.
* **No world gates against the real game.** No official jar has been downloaded
  or used yet, so there is no world-parity or level.dat-compatibility evidence.
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

* The arm64 test runner and the emulator checks do not exist yet, so **nothing
  has been executed on ARM**.
* Benchmarks do not exist yet; there are no performance numbers to quote.
