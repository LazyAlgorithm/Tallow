#!/usr/bin/env bash
# Builds the iOS player that Tallow.Build export puts into a game's app (on a Mac with Xcode; the release workflow,
# and engine source checkouts):
#
#   Player/build/Release_iOS/iphoneos/TallowPlayer          iPhones and iPads (arm64)
#   Player/build/Release_iOS/iphonesimulator/TallowPlayer   the iOS Simulator, for Intel Macs and Apple silicon (x86_64 + arm64)
#
#   tools/ios/build_player.sh [iphoneos|iphonesimulator|iphonesimulator-x86_64|iphonesimulator-arm64 ...]   default: all three
#
# The two Simulator builds are joined into one program (lipo) when both are made.
#
# The player's Beef code is compiled by BeefBuild for arm64-apple-ios15 and <arch>-apple-ios15-simulator (on any machine:
# tools/beef-patches/0002); with BEEFBUILD set it is compiled here, otherwise Player/build/Release_<triple> must hold a
# build made elsewhere. Beef's runtime is compiled from BEEF_SOURCE (a Beef source tree) with libffi.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
sdks=("$@")
[ ${#sdks[@]} -gt 0 ] || sdks=(iphoneos iphonesimulator-x86_64 iphonesimulator-arm64)
min=15.0
host_arch="$(uname -m)"
[ "$host_arch" = arm64 ] || host_arch=x86_64
beef_source="${BEEF_SOURCE:-}"
[ -n "$beef_source" ] || { [ -n "${BEEFBUILD:-}" ] && beef_source="$(cd "$(dirname "$BEEFBUILD")/../.." && pwd)"; }
[ -f "$beef_source/BeefRT/CMakeLists.txt" ] || { echo "Set BEEF_SOURCE to a Beef source tree (for Beef's runtime)." >&2; exit 1; }
work="$root/build/ios"
mkdir -p "$work"
python3 "$root/tools/patch_textedit.py" > /dev/null

for target in "${sdks[@]}"; do
	case "$target" in
	iphoneos) sdk=iphoneos; arch=arm64 ;;
	iphonesimulator) sdk=iphonesimulator; arch=$host_arch ;;
	iphonesimulator-x86_64|iphonesimulator-arm64) sdk=iphonesimulator; arch="${target#iphonesimulator-}" ;;
	*) echo "Unknown target $target (iphoneos, iphonesimulator, iphonesimulator-x86_64 or iphonesimulator-arm64)." >&2; exit 1 ;;
	esac
	if [ "$sdk" = iphoneos ]; then
		triple=arm64-apple-ios15; clang_target="arm64-apple-ios$min"
	else
		triple="$arch-apple-ios15-simulator"; clang_target="$arch-apple-ios$min-simulator"
	fi
	echo "== iOS $sdk ($arch)"
	sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
	cc="$(xcrun --sdk "$sdk" -f clang)"
	cmake_ios=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS "-DCMAKE_OSX_SYSROOT=$sdk" "-DCMAKE_OSX_ARCHITECTURES=$arch"
		"-DCMAKE_OSX_DEPLOYMENT_TARGET=$min" -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$(xcrun --sdk "$sdk" -f clang++)")

	native="$root/build/native-ios-$sdk-$arch"
	cmake -S "$root/native" -B "$native" "${cmake_ios[@]}" -DTALLOW_FLECS_EXPLORER=OFF > "$work/native-$sdk-$arch.log"
	cmake --build "$native" --target tallow_native bgfx bimg bimg_decode bx SDL3-static joltc Jolt enet >> "$work/native-$sdk-$arch.log"

	ffi="$work/ffi-$sdk-$arch"
	if [ ! -f "$ffi/.libs/libffi.a" ]; then
		rm -rf "$ffi" && mkdir -p "$ffi"
		host=$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
		(cd "$ffi" && CC="$cc -target $clang_target -isysroot $sysroot" CFLAGS="-O2 -fPIC" \
			"$beef_source/BeefySysLib/third_party/libffi/configure" --host="$host" --disable-shared --enable-static --disable-docs \
			--disable-multi-os-directory > configure.log && make -j"$(sysctl -n hw.ncpu)" > make.log)
	fi
	rt="$work/beefrt-$sdk-$arch"
	cmake -S "$beef_source/BeefRT" -B "$rt" "${cmake_ios[@]}" "-DCMAKE_C_FLAGS=-I$ffi/include" "-DCMAKE_CXX_FLAGS=-I$ffi/include" > "$work/beefrt-$sdk-$arch.log"
	cmake --build "$rt" >> "$work/beefrt-$sdk-$arch.log"
	rt_lib="$(find "$rt" -name 'libBeefRT.a' | head -1)"

	if [ -n "${BEEFBUILD:-}" ]; then
		"$BEEFBUILD" -workspace="$root/Player" -config=Release -platform="$triple" -verbosity=minimal
	fi
	objects="$root/Player/build/Release_$triple/TallowPlayer/ObjectArgs.txt"
	[ -f "$objects" ] || { echo "No Beef build for $triple ($objects): set BEEFBUILD, or compile it elsewhere and copy Player/build/Release_$triple." >&2; exit 1; }
	# Objects compiled on another machine name its folders: the same files under this checkout's Player/build.
	tr ' ' '\n' < "$objects" | grep -v '^$' | sed "s|^.*/Player/build/|$root/Player/build/|" | sed 's/.*/"&"/' > "$work/objects-$sdk-$arch.rsp"

	out="$root/Player/build/Release_iOS/$sdk"
	[ "$sdk" = iphoneos ] || out="$work/simulator-$arch"
	mkdir -p "$out"
	frameworks=(UIKit Foundation CoreFoundation CoreGraphics QuartzCore Metal AVFoundation AudioToolbox CoreAudio CoreHaptics
		CoreMotion GameController CoreVideo CoreMedia UniformTypeIdentifiers CoreBluetooth Security SystemConfiguration OpenGLES)
	"$(xcrun --sdk "$sdk" -f clang++)" -target "$clang_target" -isysroot "$sysroot" -o "$out/TallowPlayer" \
		-I"$root/third_party/SDL/include" -x c "$root/native/ios/tallow_ios_main.c" -x none "@$work/objects-$sdk-$arch.rsp" \
		"$native/libtallow_native.a" "$native/bgfx/cmake/bgfx/libbgfx.a" "$native/bgfx/cmake/bimg/libbimg.a" \
		"$native/bgfx/cmake/bimg/libbimg_decode.a" "$native/bgfx/cmake/bx/libbx.a" "$native/SDL/libSDL3.a" "$native/joltc/libjoltc.a" \
		"$native/_deps/joltphysics-build/libJolt.a" "$native/rapier/librapier3d_ffi.a" "$native/enet/libenet.a" "$rt_lib" "$ffi/.libs/libffi.a" \
		-lc++ -liconv -lz $(printf -- '-framework %s ' "${frameworks[@]}") -Wl,-rpath,@executable_path/Frameworks -Wl,-dead_strip
	# The shipped player has no debug information (dsymutil keeps it beside, for crash reports).
	dsymutil "$out/TallowPlayer" -o "$work/TallowPlayer-$sdk-$arch.dSYM" 2> /dev/null || true
	strip -S "$out/TallowPlayer"
	echo "   $(du -h "$out/TallowPlayer" | cut -f1) $out/TallowPlayer"
done

# One Simulator player for both kinds of Mac (or the one made).
simulators=("$work"/simulator-*/TallowPlayer)
if [ -f "${simulators[0]}" ]; then
	mkdir -p "$root/Player/build/Release_iOS/iphonesimulator"
	lipo -create "${simulators[@]}" -output "$root/Player/build/Release_iOS/iphonesimulator/TallowPlayer"
	echo "   Simulator player: $(lipo -archs "$root/Player/build/Release_iOS/iphonesimulator/TallowPlayer")"
fi
