#!/usr/bin/env bash
# Shared Tallow Linux development-tool installer: the Linux twin of setup_dependencies.ps1.
# The standalone launcher's Install dependencies button runs it; it installs into the same user-level toolchain
# folder Tallow Manager uses (~/.local/share/Tallow/toolchain, or $XDG_DATA_HOME/Tallow/toolchain), so either one
# finds what the other installed. No password is asked for: Beef and Python go into that folder, and the system
# packages Beef links with (a C++ compiler, X11 and OpenGL development files) are only checked, with the command
# that installs them printed when they are missing (exit status 3).
set -euo pipefail
root="${XDG_DATA_HOME:-$HOME/.local/share}/Tallow/toolchain"
release='https://github.com/LazyAlgorithm/Tallow/releases/download/v0.1.0-beta'
python_url='https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-x86_64-unknown-linux-gnu-install_only.tar.gz'
mkdir -p "$root"

download() { # url file
	if command -v curl > /dev/null; then
		curl --fail --location --retry 3 --silent --show-error -o "$2" "$1"
	elif command -v wget > /dev/null; then
		wget -q -O "$2" "$1"
	else
		echo "Neither curl nor wget is installed, so nothing can be downloaded." >&2
		return 1
	fi
}

install_archive() { # name url marker...
	local name="$1" url="$2"
	shift 2
	local have=1
	for marker in "$@"; do [ -e "$root/$marker" ] || have=0; done
	[ "$have" = 1 ] && { echo "$name is already installed."; return 0; }
	local archive
	archive="$(mktemp "${TMPDIR:-/tmp}/tallow-XXXXXX.tar.gz")"
	echo "Downloading $name"
	download "$url" "$archive" || { rm -f "$archive"; return 1; }
	[ "$(stat -c %s "$archive")" -gt 1000 ] || { rm -f "$archive"; echo "The $name download is unexpectedly small." >&2; return 1; }
	echo "Extracting $name"
	tar -xzf "$archive" -C "$root" || { rm -f "$archive"; return 1; }
	rm -f "$archive"
	for marker in "$@"; do
		[ -e "$root/$marker" ] || { echo "$name did not contain $marker." >&2; return 1; }
	done
}

python_ok() { "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' > /dev/null 2>&1; }

# A Beef the user installed themselves (the launcher sets BEEFBUILD to one it found) is used as it is.
if [ -n "${BEEFBUILD:-}" ] && [ -x "$BEEFBUILD" ] && [ "$BEEFBUILD" != "$root/beef/IDE/dist/BeefBuild.sh" ]; then
	echo "The Beef compiler is already installed: $BEEFBUILD"
else
	install_archive "the Beef compiler" "$release/beef-linux-x64.tar.gz" \
		beef/IDE/dist/BeefBuild.sh beef/BeefLibs/corlib/BeefProj.toml
fi

found_python=0
for exe in python3 python3.14 python3.13 python3.12 python3.11; do
	if command -v "$exe" > /dev/null && python_ok "$exe"; then found_python=1; break; fi
done
if [ "$found_python" = 1 ]; then
	echo "Python 3.11 or later is already installed."
else
	install_archive "Python 3.12" "$python_url" python/bin/python3
	python_ok "$root/python/bin/python3" || { echo "The installed Python does not run." >&2; exit 1; }
fi

# System packages: checked, not installed (they need the administrator password).
missing_system=0
command -v c++ > /dev/null || command -v g++ > /dev/null || command -v clang++ > /dev/null || missing_system=1
for library in libGL.so libX11.so; do
	found=0
	for folder in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu /usr/local/lib; do
		[ -e "$folder/$library" ] && found=1
	done
	[ "$found" = 1 ] || missing_system=1
done
if [ "$missing_system" = 1 ]; then
	echo
	echo "Beef links projects with your system's C++ compiler and the X11 and OpenGL development files, which"
	echo "are not all installed. Install them with (it asks for your password):"
	if command -v apt-get > /dev/null; then echo "  sudo apt-get install build-essential libgl-dev libx11-dev lld"
	elif command -v dnf > /dev/null; then echo "  sudo dnf install gcc gcc-c++ mesa-libGL-devel libX11-devel lld"
	elif command -v pacman > /dev/null; then echo "  sudo pacman -S --needed base-devel libglvnd libx11 lld"
	elif command -v zypper > /dev/null; then echo "  sudo zypper install gcc gcc-c++ Mesa-libGL-devel libX11-devel lld"
	else echo "  a C++ compiler (g++ or clang++) and the libGL and libX11 development packages"
	fi
	exit 3
fi
echo "Development tools are ready."
