# Umbra

A clean-room, Minecraft: Java Edition-compatible client for Android (arm64) and
PC (Windows x64, Linux x64). The game logic is written in
[Goose](https://github.com/aardappel/goose); the platform layer (window,
graphics context, input, audio, files) is C.

**Not an official Minecraft product.** Not approved by or associated with
Mojang or Microsoft. Umbra ships no Mojang code or assets: you use your own
copy of the game files, which stay in the app's private storage.

The official client jar is downloaded by CI (never committed) and its model data
is checked against itself: every model a blockstate can render resolves through
its parent chain to textures that exist. That is where the renderer gets its
blocks from next.

Umbra is **not** Minecraft yet. Every parity claim in this repository is a
measured match rate with the test that produced it, kept in
[STATUS.md](STATUS.md). Where there is no number, there is no claim.

## Install on an Android phone

The pre-release `v0.3.0-pre` is the first build that installs and draws a world on
a device:

```
https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.0-pre
umbra-0.3.0-pre-arm64.apk   214723 bytes
sha256 312bd4ba875d9d38abf0ee6f4a216becfb1b17291a22cab7e969e016659b35f1
```

Open that page in the phone's browser, download the `.apk`, and open it. Android
will ask you to allow installing from this source; that is expected for an app
that does not come from the Play Store. There is no PC needed and no game file to
import: the build draws a demo world. `docs/PHONE_TEST.md` is the checklist to run
once it is installed.

It is a **pre-release**: no textures yet (the world is untextured grey and green),
no world you can walk around in, and nothing from your own game files is read.

## Status

Read [STATUS.md](STATUS.md) for the current stage, verified results, and the
exact next steps. Read [KNOWN_ISSUES.md](KNOWN_ISSUES.md) before reporting a
bug. Design decisions and their reasons are in [DECISIONS.md](DECISIONS.md).

## Building

The core is Goose compiled to C, then to a native library that the C platform
layer calls:

```
goose/core/*.goose  --(goose --standalone --header)-->  build/umbra_core.c
                    --(cc / NDK clang / mingw)------->  libumbra_core
platform/*          --(cc)-------------------------->  the executable / APK
```

* Linux/macOS/Windows developer build: `tools/build_pc.sh`
* Android: `.github/workflows/android.yml` (Gradle + CMake + NDK)
* Core tests: `tools/run_tests.sh` (Goose → C → native, real assertions)
* The jar checker: `tools/check_jar.sh` (synthetic jar, no network) and
  `tools/fetch_jar.sh` (the official jar, downloaded at test time)

A `goose` binary is required. `tools/pin_goose.sh` builds the pinned commit
(see DECISIONS.md) from source with CMake.

## Licence

Umbra's own code is MIT licensed (see [LICENSE](LICENSE)). It contains no
Mojang code or assets. Game files you import remain yours and are never
redistributed by this project.
