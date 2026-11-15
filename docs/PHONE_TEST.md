# Testing Umbra on your phone

Umbra is **not** an official Minecraft product.

## What you are installing

```
https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.1-pre
umbra-0.3.1-pre-arm64.apk
```

This is a **pre-release**. It draws a demo world with the real renderer and the
real mesher, and it is not Minecraft: there are no textures yet, and you cannot
walk around or open a world.

Umbra is **not** an official Minecraft product. It ships no Mojang code or
assets; it reads your own game files from the app's private storage.

## Install

1. Open the release page linked above **on the phone** (GitHub → the repo →
   Releases; or the link in the release notes).
2. Download the file ending in `.apk` (`umbra-0.3.1-pre-arm64.apk`).
3. When Android blocks the install, tap **Settings** on the prompt and allow
   installing from this source (the browser or Files app), then tap the download
   again and choose **Install**. Android 8 and newer shows this per-app, once.
   If 0.3.0-pre is already installed this replaces it and keeps its data, so the
   first launch will already show the previous run's results.
4. If the phone asks about a Play Protect scan, choose **Install anyway** — the
   APK is signed by this project's own key, not by Google.
5. Open **Umbra** from the app drawer.

## What changed in 0.3.1 — the four things your screenshots showed

| What you saw in 0.3.0-pre | What to look for now |
|---|---|
| `LOADING WORLD 224%` | The percentage counts up to 100 and stops: `LOADING WORLD nn%`. It cannot pass 100 any more; the total is computed from the mesher itself and is checked against it in the test suite. |
| The top lines sat under the clock | Every line starts **below** the status bar. The app no longer asks Android for the old inset value, which is 0 on a phone that draws edge to edge; it asks for the modern one. |
| Only sky behind the text | The island of blocks fills the strip between the text block and the buttons, instead of sitting in the bottom corner. |
| One screenshot did not show the results | A `LAST RUN` block under the self-test line shows the previous run's verdict and benchmark numbers, so after the benchmark you can screenshot once. |

Also new: `MESH … VERTS  n DRAWS` and a `CAM eye -> look` line in the text block,
and the three buttons on one row at the bottom in landscape.

## What you should see, in order

| Step | What to do | What "passing" looks like |
|---|---|---|
| 1 | Just open it | Sky-blue screen, `UMBRA - not an official Minecraft product`, then `LOADING WORLD nn%` (never above 100) for a few seconds, then an island of blocks |
| 2 | Look at the text block, top-left | `Umbra 0.3.1  build <7 hex digits>`, `gl OpenGL ES 3.x …`, `renderer …`, `depth 24 bits  highp vs …`, `mesh … verts  n draws  frame … ms  worst … ms`, `cam …`, and **nothing under the status bar, the notch or the navigation bar** |
| 3 | Tap **RUN GPU SELF-TEST** | After a moment: `SELFTEST PASS (0 bad of 4147200 px)` in green |
| 4 | Tap **RUN 60 s BENCHMARK** | A live line (`benchmark nn/60 s  … frames  … fps live  worst … ms`) and, after a minute, a four-line block: `bench: N frames  avg X.XX ms (Y fps)`, `1% low Y fps (X.XX ms)`, `median X.XX ms  worst X.XX ms`, and the device line |
| 5 | Close the app from the app switcher and open it again | The home screen comes back with a `LAST RUN` block containing the self-test verdict and the benchmark numbers from step 3 and 4 — **and no `previous run crashed` line** |
| 6 | Tap **SHARE LOG** | The Android share sheet, offering `umbra.log` |
| 7 | Rotate the phone, then reopen | Still inside the screen, no text under the bar; the app survives being backgrounded and reopened |

**Screenshots to take:** the home screen with the text block after steps 3 and 4
(step 2 and the `LAST RUN` block in one frame), and anything that looks wrong.

## If something goes wrong

* The app writes `umbra.log` in its private storage and keeps a crash marker. If
  a run really died — not a swipe away, an actual kill or crash — the next launch
  shows `previous run crashed - log tail:` with the last two lines, and
  `SHARE LOG` sends the whole file.
* The log line `insets: L,T,R,B = …` is the one that matters if anything overlaps
  the status bar: it prints all four numbers, every answer Android gave, and which
  one the app used. If the top number is 0 on a phone with a visible status bar,
  that line is the proof.
* `camera: eye … -> look …` is the one that matters if the world is missing: it
  says where the view is pointed.
* If a single frame ever blocks for a second or more, the app says so in the log
  (`long frame … ms`), and the CI smoke test fails on the same line.

Send the shared log; it contains the build commit, the GPU strings, the inset
numbers, the mesh timing and the last error.
