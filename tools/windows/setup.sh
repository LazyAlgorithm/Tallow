#!/usr/bin/env bash
# Sets this Linux machine up to build Windows games (and the Windows editor) with Tallow. Run once; safe to run again.
#
#   tools/windows/setup.sh --accept-license
#
# It downloads, into ~/.local/share/tallow-win (or $TALLOW_WIN), about 3 GB:
#   - Microsoft's C runtime and Windows SDK libraries, with the `xwin` tool. They are Microsoft's, under the
#     Microsoft Visual Studio Build Tools licence, which --accept-license says you accept.
#   - the Windows release of the Beef compiler, which is then run under Wine;
#   - the LLVM linker (lld), if the system has none.
# Then it builds the engine's native libraries for Windows into build/native-win.
# Needs: wine, clang (with clang-cl), llvm, cmake, ninja, curl, 7z, and rpm2cpio + dnf if lld is not installed.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
win="${TALLOW_WIN:-$HOME/.local/share/tallow-win}"
[ "${1:-}" = "--accept-license" ] || { sed -n 2,13p "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 1; }
for tool in wine clang-cl llvm-lib llvm-rc llvm-mt cmake ninja curl 7z; do
	command -v "$tool" > /dev/null || { echo "Missing: $tool. Install it and run this again." >&2; exit 1; }
done
mkdir -p "$win/dl" "$win/bin"

if [ ! -f "$win/xwin/crt/lib/x86_64/libcmt.lib" ]; then
	echo "Downloading the Microsoft C runtime and Windows SDK..."
	xwin=xwin-0.10.0-x86_64-unknown-linux-musl
	curl -sL "https://github.com/Jake-Shadle/xwin/releases/download/0.10.0/$xwin.tar.gz" | tar xz -C "$win/dl"
	"$win/dl/$xwin/xwin" --accept-license --arch x86_64 --cache-dir "$win/xwin-cache" splat --output "$win/xwin"
	rm -rf "$win/xwin-cache"
fi

if [ ! -f "$win/beef/bin/BeefBuild.exe" ]; then
	echo "Downloading the Windows Beef compiler..."
	curl -sL -o "$win/dl/BeefSetup.exe" http://nightly.beeflang.org/BeefSetup.exe
	mkdir -p "$win/beef" && (cd "$win/beef" && 7z x -y ../dl/BeefSetup.exe > /dev/null)
	rm -f "$win/dl/BeefSetup.exe"
fi
# Beef finds its libraries beside itself, and the Microsoft ones where xwin put them.
printf 'Version = 1\nUnversionedLibDirs = ["../BeefLibs"]\n' > "$win/beef/bin/BeefConfig.toml"
python3 - "$win" <<'SETTINGS'
import json, sys
win = sys.argv[1]
folders = ['Z:' + (win + '/xwin/' + folder).replace('/', '\\') for folder in ('crt/lib/x86_64', 'sdk/lib/um/x86_64', 'sdk/lib/ucrt/x86_64')]
open(win + '/beef/bin/BeefSettings.toml', 'w').write('[VisualStudio]\nManuallySet = true\nBin32Path = ""\nBin64Path = ""\nLib32Paths = []\nLib64Paths = ' + json.dumps(folders) + '\n')
SETTINGS

# The linker CMake uses for the native libraries: the system's lld-link, or one unpacked from the lld package.
if command -v lld-link > /dev/null; then
	printf '#!/bin/sh\nexec lld-link "$@"\n' > "$win/bin/lld-link"
else
	if [ ! -x "$win/lld/usr/bin/lld" ]; then
		echo "Downloading the LLVM linker..."
		(cd "$win/dl" && dnf download lld lld-libs --arch x86_64 --destdir . > /dev/null)
		mkdir -p "$win/lld" && (cd "$win/lld" && for package in ../dl/lld-*.x86_64.rpm; do rpm2cpio "$package" | cpio -idm 2> /dev/null; done)
	fi
	printf '#!/bin/sh\nd="$(dirname "$(readlink -f "$0")")/../lld/usr"\nLD_LIBRARY_PATH="$d/lib64:$LD_LIBRARY_PATH" exec "$d/bin/lld" -flavor link "$@"\n' > "$win/bin/lld-link"
fi
chmod +x "$win/bin/lld-link"

echo "Starting Wine's Windows folder..."
WINEPREFIX="$win/wine" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" wine cmd /c exit > /dev/null 2>&1 || true

echo "Building the native libraries for Windows..."
python3 "$root/tools/patch_textedit.py"
cmake -S "$root/native" -B "$root/build/native-win" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$root/tools/windows/toolchain.cmake" > "$root/build/native-win.log"
cmake --build "$root/build/native-win" -j "$(nproc)"
echo "Done. Windows games can now be built: File > Build Game in the editor, or tools/build_player.py --platform windows."
