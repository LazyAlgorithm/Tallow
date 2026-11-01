# Responsive mobile UI — test checklist

Ringfall's `dev` branch builds against Tallow `dev` and deploys to the `/dev/` preview (`https://lazyalgorithm.github.io/ringfall-web/dev/`); production tracks the `main` branches. Add `?arg=--ui-debug` to the address for the size and scale readout. The design and its implementation status are in `responsive-ui-design.md`.

## Engine behavior
- UI coordinates use SDL logical window points; physical framebuffer pixels remain for the 3D renderer.
- `GUI.LogicalWidth`, `GUI.LogicalHeight`, `GUI.PixelRatio`, `GUI.IsPortrait`, `GUI.IsLandscape`, and `GUI.AspectRatio` expose the distinction.
- `UIDocument.referenceWidth` complements `referenceHeight`. When both are specified, uniform scaling uses the smaller fit factor. Existing height-only documents retain their original behavior.
- Ringfall's phone variant is designed for 600×1100 in landscape and 560×990 in portrait (`GameUi`); each screen rearranges for portrait in `@media` blocks.
- The web shell uses CSS safe-area insets on all four sides to avoid display cutouts and home indicators. SDL follows the resulting canvas box, and window resizing/reorientation should update layout.
- RenderView already renders 3D at independently configurable resolution before drawing UI; this branch does not alter it.

## Test before merge
1. Build Tallow with this branch and launch Ringfall using the existing phone variant.
2. Test iOS Safari and Android Chrome in portrait and landscape, including rotating during an active menu.
3. Check menu buttons, text, touch hit areas, scroll/clipping, notches, home indicators and text entry.
4. Compare a high-DPI phone, tablet and desktop; ensure UI dimensions are based on logical points.
5. Check game scene rendering and touch controls after rotation; confirm no 3D aspect distortion.
6. Check the browser build and static shell generation. Confirm build artifacts, no errors, and deployment remains unchanged.

## Known limitations
- The canvas must have an explicit CSS width and height: with `auto` and four insets a canvas keeps its pixel size and SDL falls back to a 1600×900 window (the October 2026 bug).
- Emulated phones (Chromium, iPhone sizes, both orientations) have been checked screen by screen; real iOS and Android devices, notches and home indicators still need a pass.
