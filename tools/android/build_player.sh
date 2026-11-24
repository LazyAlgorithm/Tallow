#!/usr/bin/env bash
# Builds the Android player that Tallow.Build export puts into a game's APK (engine source checkouts and the release
# workflow; engine packages ship the result, so making an Android game needs only Android Studio):
#
#   Player/build/Release_Android/<abi>/libmain.so   the engine and player for arm64-v8a (phones) and x86_64 (emulator)
#   Player/build/Release_Android/classes.dex         SDL's Java activity and Tallow's (org.tallowengine.player)
#
#   tools/android/build_player.sh [abi...]           default: arm64-v8a x86_64
#
# Needs: the Android SDK with an NDK (ANDROID_HOME, or Android Studio's usual folder), a JDK (Android Studio's own,
# or JAVA_HOME), CMake and Ninja, and BeefBuild (BEEFBUILD) from a Beef source tree: Beef's runtime is compiled for
# Android from that tree (BEEF_SOURCE, default the tree BeefBuild is in), with libffi.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
abis=("$@")
[ ${#abis[@]} -gt 0 ] || abis=(arm64-v8a x86_64)
# Android 10: the oldest with ELF thread-local storage, which Beef's thread-local fields compile to.
api=29

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
for candidate in "$sdk" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
	if [ -n "$candidate" ] && [ -d "$candidate/platforms" ]; then sdk="$candidate"; break; fi
done
[ -d "$sdk/platforms" ] || { echo "No Android SDK found: install Android Studio or set ANDROID_HOME." >&2; exit 1; }
ndk="${ANDROID_NDK_HOME:-}"
[ -n "$ndk" ] || ndk="$(ls -d "$sdk"/ndk/*/ 2>/dev/null | sort -V | tail -1)"
ndk="${ndk%/}"
[ -f "$ndk/build/cmake/android.toolchain.cmake" ] || { echo "No NDK in $sdk/ndk: install it (Android Studio > SDK Manager > SDK Tools > NDK)." >&2; exit 1; }
host_tag="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"
toolchain="$ndk/toolchains/llvm/prebuilt/$host_tag/bin"
platform_jar="$(ls -d "$sdk"/platforms/android-*/android.jar | sort -V | tail -1)"
build_tools="$(ls -d "$sdk"/build-tools/*/ | sort -V | tail -1)"
java_home="${JAVA_HOME:-}"
for candidate in "$java_home" "$HOME/Applications/android-studio/jbr" "/opt/android-studio/jbr" "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
	if [ -n "$candidate" ] && [ -x "$candidate/bin/javac" ]; then java_home="$candidate"; break; fi
done
[ -x "$java_home/bin/javac" ] || java_home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"

beefbuild="${BEEFBUILD:-$(command -v BeefBuild)}"
beef_source="${BEEF_SOURCE:-$(cd "$(dirname "$(readlink -f "$beefbuild")")/../.." && pwd)}"
[ -f "$beef_source/BeefRT/CMakeLists.txt" ] || { echo "No Beef source tree at $beef_source (set BEEF_SOURCE)." >&2; exit 1; }

out="$root/Player/build/Release_Android"
work="$root/build/android"
mkdir -p "$out" "$work"

# Beef's runtime sources, with what bionic needs (sigaction's first member is not the handler there).
rt_source="$work/beef-src"
rm -rf "$rt_source" && mkdir -p "$rt_source"
cp -r "$beef_source/BeefRT" "$beef_source/BeefySysLib" "$beef_source/extern" "$rt_source/"
sed -i.orig 's/struct sigaction ignoreAction = { SIG_IGN };/struct sigaction ignoreAction = {}; ignoreAction.sa_handler = SIG_IGN;/' \
	"$rt_source/BeefySysLib/platform/posix/PosixCommon.cpp"

python3 "$root/tools/patch_textedit.py" > /dev/null

for abi in "${abis[@]}"; do
	case "$abi" in
	arm64-v8a) triple=aarch64-linux-android ;;
	x86_64) triple=x86_64-linux-android ;;
	*) echo "Unknown ABI $abi (arm64-v8a or x86_64)." >&2; exit 1 ;;
	esac
	echo "== Android $abi"
	cmake_android=(-G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_TOOLCHAIN_FILE=$ndk/build/cmake/android.toolchain.cmake"
		"-DANDROID_ABI=$abi" "-DANDROID_PLATFORM=android-$api")

	# The engine's native libraries.
	native="$root/build/native-android-$abi"
	cmake -S "$root/native" -B "$native" "${cmake_android[@]}" -DTALLOW_FLECS_EXPLORER=OFF > "$work/native-$abi.log"
	cmake --build "$native" --target tallow_native bgfx bimg bimg_decode bx SDL3-static joltc Jolt enet >> "$work/native-$abi.log"

	# libffi (Beef's reflection calls) and Beef's runtime.
	ffi="$work/ffi-$abi"
	if [ ! -f "$ffi/.libs/libffi.a" ]; then
		rm -rf "$ffi" && mkdir -p "$ffi"
		(cd "$ffi" && CC="$toolchain/$triple$api-clang" CXX="$toolchain/$triple$api-clang++" AR="$toolchain/llvm-ar" \
			RANLIB="$toolchain/llvm-ranlib" CFLAGS="-O2 -fPIC" "$rt_source/BeefySysLib/third_party/libffi/configure" \
			--host="$triple" --disable-shared --enable-static --disable-docs --disable-multi-os-directory > configure.log \
			&& make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" > make.log)
	fi
	rt="$work/beefrt-$abi"
	cmake -S "$rt_source/BeefRT" -B "$rt" "${cmake_android[@]}" "-DCMAKE_C_FLAGS=-I$ffi/include" "-DCMAKE_CXX_FLAGS=-I$ffi/include" > "$work/beefrt-$abi.log"
	cmake --build "$rt" >> "$work/beefrt-$abi.log"

	# The player, compiled by Beef into static archives; ObjectArgs.txt names exactly this build's objects.
	"$beefbuild" -workspace="$root/Player" -config=Release -platform="$triple" -verbosity=minimal
	objects="$root/Player/build/Release_$triple/TallowPlayer/ObjectArgs.txt"
	tr ' ' '\n' < "$objects" | grep -v '^$' | sed 's/.*/"&"/' > "$work/objects-$abi.rsp"

	mkdir -p "$out/$abi"
	"$toolchain/$triple$api-clang++" -shared -fPIC -o "$out/$abi/libmain.so" -I"$root/third_party/SDL/include" \
		-x c "$root/native/android/tallow_android_main.c" -x none "@$work/objects-$abi.rsp" \
		-Wl,--start-group "$native/libtallow_native.a" "$native/bgfx/cmake/bgfx/libbgfx.a" "$native/bgfx/cmake/bimg/libbimg.a" \
		"$native/bgfx/cmake/bimg/libbimg_decode.a" "$native/bgfx/cmake/bx/libbx.a" "$native/SDL/libSDL3.a" "$native/joltc/libjoltc.a" \
		"$native/_deps/joltphysics-build/libJolt.a" "$native/rapier/librapier3d_ffi.a" "$native/enet/libenet.a" \
		"$rt/Release/bin/libBeefRT.a" "$ffi/.libs/libffi.a" -Wl,--end-group \
		-static-libstdc++ -landroid -llog -lEGL -lGLESv3 -lOpenSLES -laaudio -lm -ldl \
		-Wl,--no-undefined -Wl,-z,max-page-size=16384 -Wl,--build-id=sha1
	# The shipped library has no debug information; the full one stays beside it for crash reports.
	cp "$out/$abi/libmain.so" "$work/libmain-$abi.debug.so"
	"$toolchain/llvm-strip" --strip-debug "$out/$abi/libmain.so"
	echo "   $(du -h "$out/$abi/libmain.so" | cut -f1) $out/$abi/libmain.so"
done

# The Java side: SDL's activity and Tallow's, for any game (the package name lives in each game's manifest).
classes="$work/classes"
rm -rf "$classes" && mkdir -p "$classes"
"$java_home/bin/javac" --release 11 -nowarn -classpath "$platform_jar" -d "$classes" \
	"$root/third_party/SDL/android-project/app/src/main/java/org/libsdl/app/"*.java "$root/tools/android/java/org/tallowengine/player/"*.java 2> "$work/javac.log" \
	|| { cat "$work/javac.log" >&2; exit 1; }
rm -f "$out/classes.dex"
JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" "$build_tools/d8" --release --min-api "$api" --lib "$platform_jar" --output "$out" \
	$(find "$classes" -name '*.class')
echo "   $out/classes.dex"
