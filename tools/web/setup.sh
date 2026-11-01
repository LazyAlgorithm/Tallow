#!/usr/bin/env bash
# One-time setup for building games for the web (WebAssembly). Run it again after updating Beef or Tallow's native/.
#
#   1. Emscripten (the compiler that targets browsers), into ~/.local/share/tallow-web/emsdk unless EMSDK is set
#   2. Beef's WebAssembly runtime library, built from the Beef source next to your BeefBuild
#   3. Beef's setting that says where Emscripten is ([Wasm] EmscriptenPath in BeefSettings.toml)
#   4. the engine's native libraries for the web, into build/native-web
#   5. the engine's shaders, including the WebGL 2 ones
#
# Needs: BeefBuild on PATH (or BEEFBUILD set) from a Beef source build, git, Python 3, CMake, Ninja, and the
# desktop build done once (./build.sh), which makes the shader compiler.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# Emscripten 4.0.23 uses the same LLVM major version (22) as Beef's compiler, so their object files link together.
EMSCRIPTEN_VERSION="${EMSCRIPTEN_VERSION:-4.0.23}"
EMSDK="${EMSDK:-$HOME/.local/share/tallow-web/emsdk}"

# ---- 1. Emscripten ----
if [ ! -x "$EMSDK/upstream/emscripten/emcc" ]; then
	echo "Installing Emscripten $EMSCRIPTEN_VERSION into $EMSDK..."
	mkdir -p "$(dirname "$EMSDK")"
	[ -d "$EMSDK/.git" ] || git clone --depth 1 https://github.com/emscripten-core/emsdk "$EMSDK"
	"$EMSDK/emsdk" install "$EMSCRIPTEN_VERSION"
	"$EMSDK/emsdk" activate "$EMSCRIPTEN_VERSION"
fi
export PATH="$EMSDK/upstream/emscripten:$PATH"
emcc --version | head -1

# ---- 2. Beef's WebAssembly runtime ----
beef="$(command -v "${BEEFBUILD:-BeefBuild}" || true)"
[ -n "$beef" ] || { echo "BeefBuild was not found: put it on PATH or set BEEFBUILD." >&2; exit 1; }
beef_dist="$(cd -- "$(dirname -- "$(readlink -f "$beef")")" && pwd)"
beef_root="$(cd -- "$beef_dist/../.." && pwd)"
if ! ls "$beef_dist"/Beef*RT32_wasm.a >/dev/null 2>&1; then
	[ -x "$beef_root/wasm/build_wasm.sh" ] || { echo "Beef's WebAssembly runtime needs the Beef source tree ($beef_root/wasm/build_wasm.sh). Update Beef from source." >&2; exit 1; }
	echo "Building Beef's WebAssembly runtime..."
	(cd "$beef_root/wasm" && ./build_wasm.sh release)
fi

# ---- 3. Tell Beef where Emscripten is ----
settings="$beef_dist/BeefSettings.toml"
python3 - "$settings" "$EMSDK/" <<'PY'
import re, sys
from pathlib import Path
path, emsdk = Path(sys.argv[1]), sys.argv[2]
text = path.read_text() if path.exists() else 'FileVersion = 1\n'
entry = f'EmscriptenPath = "{emsdk}"'
if re.search(r'^\[Wasm\]\s*$', text, re.M):
    section = re.search(r'^\[Wasm\]\s*$(.*?)(?=^\[|\Z)', text, re.M | re.S)
    body = section.group(1)
    body = re.sub(r'^EmscriptenPath\s*=.*$', entry, body, flags=re.M) if 'EmscriptenPath' in body else '\n' + entry + body
    text = text[:section.start(1)] + body + text[section.end(1):]
else:
    text = text.rstrip('\n') + f'\n\n[Wasm]\n{entry}\n'
path.write_text(text)
PY
echo "Beef will use Emscripten from $EMSDK"

# ---- 4. Native libraries ----
"$root/tools/web/build_native.sh"

# ---- 5. Shaders ----
if [ -x "${SHADERC:-$root/build/native/bgfx/cmake/bgfx/shaderc}" ]; then
	"$root/tools/compile_shaders.sh"
else
	echo "Note: the shader compiler is missing; run ./build.sh, then tools/compile_shaders.sh, to make the WebGL shaders." >&2
fi
echo "Done. Build a game for the web from the editor (File > Build..., For: Web) or with:"
echo "  python3 $root/tools/build_player.py /path/to/project --platform web --output /path/to/folder"
