# Testing Umbra on your phone

Umbra is **not** an official Minecraft product.

## What you are installing

```
https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.0-pre
umbra-0.3.0-pre-arm64.apk   214723 bytes
sha256 312bd4ba875d9d38abf0ee6f4a216becfb1b17291a22cab7e969e016659b35f1
```

This is a **pre-release**. It draws a demo world with the real renderer and the
real mesher, and it is not Minecraft: there are no textures yet, and you cannot
walk around or open a world.

Umbra is **not** an official Minecraft product. It ships no Mojang code or
assets; it reads your own game files from the app's private storage.

## Install

1. Open the release page linked above **on the phone** (GitHub → the repo →
   Releases; or the link in the release notes).
2. Download the file ending in `.apk` (`umbra-0.3.0-pre-arm64.apk`).
3. When Android blocks the install, tap **Settings** on the prompt and allow
   installing from this source (the browser or Files app), then tap the download
   again and choose **Install**. Android 8 and newer shows this per-app, once.
4. If the phone asks about a Play Protect scan, choose **Install anyway** — the
   APK is signed by this project's own key, not by Google.
5. Open **Umbra** from the app drawer.

## What you should see, in order

| Step | What to do | What "passing" looks like |
|---|---|---|
| 1 | Just open it | Sky-blue screen, `UMBRA - not an official Minecraft product`, then `LOADING WORLD nn%` for a couple of seconds, then an island of blocks |
| 2 | Look at the text block, top-left | `Umbra 0.3.0  build <7 hex digits>`, `gl OpenGL ES 3.x …`, `renderer …`, `depth 24 bits  highp vs …`, `mesh … verts … indices  frame … ms  worst … ms` — **nothing may sit under the status bar or the notch** |
| 3 | Tap **RUN GPU SELF-TEST** | After a moment: `SELFTEST PASS (0 bad of 4147200 px)` in green, and the matching lines in the log |
| 4 | Tap **RUN 60 s BENCHMARK** | A live line (`benchmark nn/60 s  … frames  … fps live  worst … ms`) and, after a minute, a four-line block: `bench: N frames  avg X.XX ms (Y fps)`, `1% low Y fps (X.XX ms)`, `median X.XX ms  worst X.XX ms`, and the device line |
| 5 | Tap **SHARE LOG** | The Android share sheet, offering `umbra.log` |
| 6 | Rotate the phone, then reopen | Still inside the screen, no text under the bar; the app survives being backgrounded and reopened |

**Screenshots to take:** the home screen with the text block (step 2), the green
`SELFTEST PASS` line (step 3), and the benchmark line (step 4). Those three are
what a bug report needs.

## If something goes wrong

* The app writes `umbra.log` in its private storage and keeps a crash marker. If
  the previous run died, the next launch shows `previous run crashed - log tail:`
  with the last two lines, and `SHARE LOG` sends the whole file.
* A black screen with no text is different from a crash: it means the app is
  drawing but the world never finished meshing. The log line
  `startup: meshed in …` is the one to look for.
* If a single frame ever blocks for a second or more, the app says so in the log
  (`long frame … ms`), and the CI smoke test fails on the same line.

Send the shared log; it contains the build commit, the GPU strings, the mesh
timing and the last error.
