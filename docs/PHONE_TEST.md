# Testing Umbra on your phone

Umbra is **not** an official Minecraft product.

## What you are installing

```
https://github.com/entitybrian69-bit/Umbra-launcher-/releases/tag/v0.3.9-pre
umbra-0.3.4-pre-arm64.apk
```

This is a **pre-release**. It draws a world with the real renderer and the real
mesher, and you can walk around in it, break blocks and place them. The textures and
block models are read from your own copy of the game files: the screen called **GET
THE GAME'S FILES** downloads the pinned client jar from Mojang (41 483 720 bytes,
checked against a pinned SHA-1) or takes a jar you already have.

**A world you generated can be opened.** Zip a world's `region` folder (the folder that
holds `r.<x>.<z>.mca` files) and put the zip at `.../files/world.zip` in the app's own
directory, or use the screen's **OPEN A WORLD THE GAME MADE** button and pick the zip.
Umbra opens a 25-chunk window around that world's origin and draws the save's own
blocks, with the game's own models and textures. A bigger world is cut down to that
window and the log says how much was left out.

It is still not Minecraft: there is one dimension, no mobs, no survival mode, no
crafting, no redstone, and no multiplayer. Worldgen parity -- biomes, caves, ores,
structures -- is not done; a world Umbra generates itself is a demo scene, and only a
save you open is the real thing.

Umbra is **not** an official Minecraft product. It ships no Mojang code or
assets; it reads your own game files from the app's private storage.

## Install

1. Open the release page linked above **on the phone** (GitHub → the repo →
   Releases; or the link in the release notes).
2. Download the file ending in `.apk` (`umbra-0.3.4-pre-arm64.apk`).
3. When Android blocks the install, tap **Settings** on the prompt and allow
   installing from this source (the browser or Files app), then tap the download
   again and choose **Install**. Android 8 and newer shows this per-app, once.
   If an older Umbra is already installed this replaces it and keeps its data, so
   the first launch will already show that run's results.
4. If the phone asks about a Play Protect scan, choose **Install anyway** — the
   APK is signed by this project's own key, not by Google.
5. Open **Umbra** from the app drawer.

## What is new in 0.3.4

* **Textures.** The world is textured, from a 128x128 atlas of twelve placeholder
  tiles packed by this project. Leaves have holes, water is blended, and a missing
  texture would show as magenta and be counted rather than hidden.
* **Walking.** Tap the world to drop into first person. Drag to look, rest a finger
  for about half a second to walk forward, tap to jump. The HUD line `you x y z yaw`
  is your body; `ground` or `air` says whether you are standing.
* **A real block model.** The half-height plank path in the world is drawn from a
  block model (a JSON box with its own uv rects and a `cullface`), not from a cube,
  and you walk on it at half height. That is the same path the game's own 4192 block
  models take — CI parses all of them with the same parser and refuses none.

## What changed in 0.3.2 — the three numbers your last run produced

| What your last run showed | What to look for now |
|---|---|
| `GPU self-test FAIL: 2458665 bad of 4950720 px` | The cause was a shader that computed in 16-bit integers on your GPU, so the test pattern only matched in one corner of the screen. It is fixed, and the test now says `SELFTEST PASS (0 bad of N px, … ms, offscreen)` with N in the millions. |
| the run before that ended at `SELF-TEST: BEGIN` and looked like a crash | It was not a crash: the test did five million comparisons in one frame and Android closed the app for not responding. It now takes 32 small steps and logs each one, so a slow test is slow, not fatal. |
| the benchmark said 59 FPS | That was your screen's 60 Hz, not the GPU. The app now asks for an uncapped swap interval and says whether the phone allowed it, and it reports GPU time separately when the driver offers timer queries. |

The log now also answers the device questions by name before anything else runs:
`check: renderer …`, `check: gl version …`, `check: max texture size …`,
`check: gpu timer query …`, `check: shader programs mesh ok, hud ok, pattern ok,
cube ok`, `check: depth buffer …`, and then either `check: all device checks
passed` or `check: running in fallback: <why>`. If a check fails, the app draws a
plain background with that one line on it instead of crashing.

## What you should see, in order

| Step | What to do | What "passing" looks like |
|---|---|---|
| 1 | Just open it | Sky-blue screen, `UMBRA - not an official Minecraft product`, then `LOADING WORLD nn%` (never above 100) for a few seconds, then an island of blocks |
| 2 | Look at the text block, top-left | `Umbra 0.3.4  build <7 hex digits>`, `gl OpenGL ES 3.x …`, `renderer …`, `depth 24 bits  highp vs …`, `mesh … verts  n draws  frame … ms  worst … ms`, `cam …`, and **nothing under the status bar, the notch or the navigation bar**. A red `fallback: …` line means a device check failed; that line is the reason |
| 3 | Tap **RUN GPU SELF-TEST** | After a moment: `SELFTEST PASS (0 bad of N px, … ms, offscreen)` in green, with N in the millions. `SELFTEST FAIL` shows the first mismatch as `at x,y got r,g,b want r,g,b` |
| 4 | Tap **RUN 60 s BENCHMARK** | A live line, then a six-line block: `bench: N frames  avg X.XX ms (Y fps)`, `1% low …`, `median … worst …`, the device line, `gpu avg X.XX ms over N frames` (or `gpu n/a (no GPU timer results)`), and `vsync: uncapped requested`, `refused` or `capped by the platform` |
| 5 | Close the app from the app switcher and open it again | The home screen comes back with a `LAST RUN` block containing the self-test verdict and the benchmark numbers from steps 3 and 4 — **and no `previous run crashed` line** |
| 6 | Tap **SHARE LOG** | The Android share sheet, offering `umbra.log` |
| 7 | Tap the world, drag, then hold a finger still | First person: the HUD line changes to `you …` with `ground` underfoot, dragging turns the view, and a held finger walks (the numbers move). A tap jumps |
| 8 | Rotate the phone, then reopen | Still inside the screen, no text under the bar; the app survives being backgrounded and reopened |

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
