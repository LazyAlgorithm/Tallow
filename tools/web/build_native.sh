#!/usr/bin/env bash
# Builds the engine's native libraries for the web (WebAssembly) into build/native-web.
# Needs Emscripten on PATH (see tools/web/setup.sh).
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v emcmake >/dev/null || { echo "emcmake not found: run tools/web/setup.sh and put Emscripten on PATH." >&2; exit 1; }
python3 "$root/tools/patch_textedit.py"
emcmake cmake -S "$root/native" -B "$root/build/native-web" -G Ninja -DCMAKE_BUILD_TYPE=Release
# Only what a game links; bimg's texture encoder (an editor tool) uses x86 intrinsics.
cmake --build "$root/build/native-web" -j "$(nproc)" --target tallow_native bgfx bimg bimg_decode bx SDL3-static joltc Jolt enet
