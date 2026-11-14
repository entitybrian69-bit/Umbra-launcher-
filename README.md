# Umbra

A clean-room, Minecraft: Java Edition-compatible client for Android (arm64) and
PC (Windows x64, Linux x64). The game logic is written in
[Goose](https://github.com/aardappel/goose); the platform layer (window,
graphics context, input, audio, files) is C.

**Not an official Minecraft product.** Not approved by or associated with
Mojang or Microsoft. Umbra ships no Mojang code or assets: you use your own
copy of the game files, which stay in the app's private storage.

Umbra is **not** Minecraft yet. Every parity claim in this repository is a
measured match rate with the test that produced it, kept in
[STATUS.md](STATUS.md). Where there is no number, there is no claim.

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

A `goose` binary is required. `tools/pin_goose.sh` builds the pinned commit
(see DECISIONS.md) from source with CMake.

## Licence

Umbra's own code is MIT licensed (see [LICENSE](LICENSE)). It contains no
Mojang code or assets. Game files you import remain yours and are never
redistributed by this project.
