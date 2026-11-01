# Roadmap

Status on 2026-10-13, and the work agreed and queued, in order.

**How to use this page.** Work happens on `dev` (Tallow and the games), and reaches `main` only once it is checked.
Each queued item is a checkbox: `[x]` done (with the date and the commit), `[~]` in progress (with notes on what is
built and what is left, so anyone can pick it up), `[ ]` not started. Tick an item in the same commit that finishes
it. Every engine feature is only done when it has:

The website is the GitHub Pages site on this repository's `gh-pages` branch (one page, `index.html`). Its **Manual**
documents each feature in a section of its own (an `h2` with an id, linked from the Manual's sidebar; the site's
search picks it up). A feature on `dev` but not yet in `main` says so in its section.

## Done

- Terrain redesign (tiles, generators, LOD, undo); faster CI that caches the native libraries and compilers
- Ringfall: aim assist per weapon and per control type, auto-fire buffer
- Layers, tags and world states. World states now cover collision, drawing, shadows, lights, particles, sound and
  navigation, with a world state menu in the editor toolbar
- HTTPS downloads and zip extraction in the engine (`docs/http.md`)
- Built games: `windowWidth`, `windowHeight` and `escapeQuits` in `project.tallow`; engine releases carry
  `SHA256SUMS.txt`
- **Responsive UI and mobile controls** (2026-10-13, `dev` and `main`): the web canvas sized correctly (it was a
  1600×900 window on phones), SDL following resizes in fullscreen (a phone turned after play started was
  stretched), `@media` rules in UI stylesheets, text measured at the width it is drawn, touch controls in the
  screen's short side, dimmed buttons, sticks hidden until used, flicks (`AddSwipe`), phone 3D resolution by the
  short side. Ringfall: portrait and landscape layouts for every phone screen and the HUD, buttons-only touch
  controls around FIRE, mantling per input type. Docs: `responsive-ui-design.md`, `input.md` (touch), Ringfall's
  `mobile-controls-v2.md`. Website: Manual > Touch screens, Phones and tablets.
- **Tallow Hub** (github.com/LazyAlgorithm/tallow-hub): installs, updates and starts Ringfall and the engine,
  checks for and installs the tools they need after asking, beta badges and a beta-builds setting, and updates
  itself. Linux and Windows builds are on its Releases page. Tested on Linux: browsing, the tools dialog, installing
  the engine, starting it, settings. Windows built but not yet tried on a real Windows machine.

## Manual steps

1. **Add the `RELEASES_TOKEN` secret to the Ringfall repository** (Settings > Secrets and variables > Actions). It is
   a fine-grained personal access token with *Contents: Read and write* on `LazyAlgorithm/ringfall-releases`. Until
   it is there, Ringfall builds skip the public release (the run shows a notice), so the Hub shows "No release yet"
   for Ringfall. After adding it, push Ringfall to its `release` branch (or run its workflow) once.
2. Try the Hub on Windows: unzip TallowHub-Windows.zip from the tallow-hub Releases page and run TallowHub.exe.
3. Optional: try Tallow on a real Mac (E18, `docs/macos.md`); the Hub has no macOS build yet. macOS CI builds are paused
   (2026-10-27, `macos.yml` runs only by hand) until a Mac is available to check them.

## Queued

Work agreed and queued, in order (see *How to use this page* above for what "done" means).

## Shatterline engine features (general-purpose first)

## Higher-quality rendering (after the above, one at a time)

## Editor

## Last