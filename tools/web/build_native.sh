#!/usr/bin/env bash
# Builds the engine's native libraries for the web (WebAssembly) into build/native-web.
# Needs Emscripten on PATH (see tools/web/setup.sh).
# Threads (the default) compile the libraries with -pthread, so their locks, atomics and thread-locals are the
# threaded ones; TALLOW_WEB_THREADS=0 builds them without threads.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v emcmake >/dev/null || { echo "emcmake not found: run tools/web/setup.sh and put Emscripten on PATH." >&2; exit 1; }
threads="${TALLOW_WEB_THREADS:-1}"
flags=()
case "$threads" in 0|false|no|off|False|No|Off) ;; *) flags=(-DCMAKE_C_FLAGS=-pthread -DCMAKE_CXX_FLAGS=-pthread) ;; esac
python3 "$root/tools/patch_textedit.py"
emcmake cmake -S "$root/native" -B "$root/build/native-web" -G Ninja -DCMAKE_BUILD_TYPE=Release "${flags[@]}"
# Only what a game links; bimg's texture encoder (an editor tool) uses x86 intrinsics.
cmake --build "$root/build/native-web" -j "$(getconf _NPROCESSORS_ONLN)" --target tallow_native bgfx bimg bimg_decode bx SDL3-static joltc Jolt enet
