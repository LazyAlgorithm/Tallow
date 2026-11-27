cmake_minimum_required(VERSION 3.20)
project(tallow_native C CXX)

# Builds every native dependency of the Tallow engine as static libraries.
# The Beef projects link the resulting archives (see Engine/BeefProj.toml).

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
	set(CMAKE_BUILD_TYPE Release)
endif()

set(TP ${CMAKE_CURRENT_SOURCE_DIR}/../third_party)
# Flecs Explorer support (REST, HTTP, stats, JSON) in a Release native build, for the editor.
option(TALLOW_FLECS_EXPLORER "Build Flecs's Explorer addons (REST server, started on request)" ON)

if(EMSCRIPTEN)
	# Emscripten turns SSE into WebAssembly SIMD. bx asks for SSE 4.2 on every non-MSVC compiler, and Jolt's headers
	# use SSE when built for WebAssembly SIMD, so everything that includes them needs both flags.
	add_compile_options(-msimd128 -msse4.2)
endif()

# ---- bgfx (renderer: Vulkan / Metal / D3D11 / D3D12 / GLES / WebGL) ----
set(BGFX_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BGFX_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BGFX_INSTALL OFF CACHE BOOL "" FORCE)
set(BGFX_CUSTOM_TARGETS OFF CACHE BOOL "" FORCE)
# shaderc: the editor runs it to compile a project's own shaders. The Windows cross-build makes shaderc.exe for the
# Windows editor.
set(BGFX_BUILD_TOOLS ON CACHE BOOL "" FORCE)
if(EMSCRIPTEN)
	# A web build (emcmake cmake ..., see Tallow.Build web-setup --engine-pieces) runs in a browser: shaderc is a desktop tool,
	# and there is a single thread, so bgfx renders on the thread that calls frame().
	set(BGFX_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
	set(BGFX_CONFIG_MULTITHREADED OFF CACHE BOOL "" FORCE)
endif()
if(ANDROID OR IOS)
	# An Android or iOS build (the NDK's toolchain file, see tools/android) is only the game's libraries: shaderc and texturec
	# are desktop tools that the editor and Tallow.Build export run.
	set(BGFX_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
endif()
set(BGFX_BUILD_TOOLS_GEOMETRY OFF CACHE BOOL "" FORCE)
# texturec: Tallow.Build export compresses a game's pictures with it (BC7 .ktx with mip levels).
set(BGFX_BUILD_TOOLS_TEXTURE ON CACHE BOOL "" FORCE)
set(BGFX_BUILD_TOOLS_BIN2C OFF CACHE BOOL "" FORCE)
set(BGFX_CONFIG_VIDEO OFF CACHE BOOL "" FORCE)
# Linux windows are X11 (XWayland on Wayland desktops). With bgfx's Wayland path compiled in,
# its OpenGL backend hands the X11 display to EGL as a Wayland display and crashes.
set(BGFX_WITH_WAYLAND OFF CACHE BOOL "" FORCE)
add_subdirectory(${TP}/bgfx.cmake bgfx)

# ---- SDL3 (window, input, gamepads, audio device) ----
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(${TP}/SDL SDL)

# ---- ENet (reliable / unreliable UDP transport) ----
add_subdirectory(${TP}/enet enet)

# ---- Jolt Physics through the JoltC C API ----
set(JPH_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(JPH_SAMPLES OFF CACHE BOOL "" FORCE)
set(JPH_TESTS OFF CACHE BOOL "" FORCE)
set(JPH_INSTALL OFF CACHE BOOL "" FORCE)
set(INTERPROCEDURAL_OPTIMIZATION OFF CACHE BOOL "" FORCE)
# Bit-identical simulation is what makes client-side physics prediction converge.
set(CROSS_PLATFORM_DETERMINISTIC ON CACHE BOOL "" FORCE)
set(USE_AVX OFF CACHE BOOL "" FORCE)
set(USE_AVX2 OFF CACHE BOOL "" FORCE)
set(USE_FMADD OFF CACHE BOOL "" FORCE)
set(USE_F16C OFF CACHE BOOL "" FORCE)
set(USE_LZCNT OFF CACHE BOOL "" FORCE)
set(USE_TZCNT OFF CACHE BOOL "" FORCE)
set(FLOATING_POINT_EXCEPTIONS_ENABLED OFF CACHE BOOL "" FORCE)
set(DEBUG_RENDERER_IN_DEBUG_AND_RELEASE OFF CACHE BOOL "" FORCE)
set(DEBUG_RENDERER_IN_DISTRIBUTION OFF CACHE BOOL "" FORCE)
set(PROFILER_IN_DEBUG_AND_RELEASE OFF CACHE BOOL "" FORCE)
set(JPH_USE_DX12 OFF CACHE BOOL "" FORCE)
set(JPH_USE_VK OFF CACHE BOOL "" FORCE)
set(JPH_USE_MTL OFF CACHE BOOL "" FORCE)
if(EMSCRIPTEN)
	# WebAssembly SIMD: every current browser has it, and Jolt is much faster with it.
	set(USE_WASM_SIMD ON CACHE BOOL "" FORCE)
endif()
add_subdirectory(${TP}/joltc joltc)

# Focused diagnostic instrumentation: only the convex dispatch translation unit is rebuilt with Jolt's
# external profiler. Production builds leave it off. Callbacks are thread-local and set only during queries.
option(TALLOW_PROFILE_CONVEX_QUERIES "Expose Jolt convex and EPA scopes to the engine profiler" OFF)
if(TALLOW_PROFILE_CONVEX_QUERIES)
	get_target_property(_tallow_jolt_sources Jolt SOURCES)
	foreach(_tallow_jolt_source IN LISTS _tallow_jolt_sources)
		if(_tallow_jolt_source MATCHES "/ConvexShape\\.cpp$")
			set_source_files_properties(${_tallow_jolt_source}
				TARGET_DIRECTORY Jolt PROPERTIES COMPILE_DEFINITIONS JPH_EXTERNAL_PROFILE SKIP_PRECOMPILE_HEADERS ON)
		endif()
	endforeach()
endif()
# Preserve Jolt's registered fallback when installing query-only shape specializations. The upstream header
# exposes registration but no lookup; add a read-only inline accessor to the fetched dependency.
get_target_property(_tallow_jolt_sources Jolt SOURCES)
foreach(_tallow_jolt_source IN LISTS _tallow_jolt_sources)
	if(_tallow_jolt_source MATCHES "/CollisionDispatch\\.cpp$")
		get_filename_component(_tallow_collision_dir ${_tallow_jolt_source} DIRECTORY)
		set(_tallow_dispatch_header "${_tallow_collision_dir}/CollisionDispatch.h")
		file(READ ${_tallow_dispatch_header} _tallow_dispatch_text)
		if(NOT _tallow_dispatch_text MATCHES "sGetCollideShape")
			string(REPLACE "\nprivate:" "\n\t// Tallow: preserve the original dispatcher for query-only specializations.\n\tstatic CollideShape sGetCollideShape(EShapeSubType a, EShapeSubType b) { return sCollideShape[(int)a][(int)b]; }\nprivate:" _tallow_dispatch_text "${_tallow_dispatch_text}")
			file(WRITE ${_tallow_dispatch_header} "${_tallow_dispatch_text}")
		endif()
	endif()
endforeach()

# Recast/Detour v1.6.0, vendored at 6dc1667f580357e8a2154c28b7867bea7e8ad3a7.
# Include the objects in our existing archive so all desktop/web consumers keep the same link interface.
file(GLOB TALLOW_RECAST_SOURCES CONFIGURE_DEPENDS ${TP}/recastnavigation/Recast/Source/*.cpp ${TP}/recastnavigation/Detour/Source/*.cpp)
add_library(tallow_navigation OBJECT tallow_navigation.cpp ${TALLOW_RECAST_SOURCES})
target_compile_features(tallow_navigation PRIVATE cxx_std_17)
target_include_directories(tallow_navigation PRIVATE ${TP}/recastnavigation/Recast/Include ${TP}/recastnavigation/Detour/Include ${TP}/joltc/include)
target_link_libraries(tallow_navigation PRIVATE Jolt)

# Cluster LOD (ClusterMesh): clusterlod.h on top of meshoptimizer 1.2, the copy bgfx bundles (bgfx.cmake only builds it
# for its own tools, so these objects are the only meshoptimizer in the archive).
file(GLOB TALLOW_MESHOPT_SOURCES CONFIGURE_DEPENDS ${TP}/bgfx.cmake/bgfx/3rdparty/meshoptimizer/src/*.cpp)
add_library(tallow_clusterlod OBJECT tallow_clusterlod.cpp ${TALLOW_MESHOPT_SOURCES})
target_compile_features(tallow_clusterlod PRIVATE cxx_std_17)
target_include_directories(tallow_clusterlod PRIVATE ${TP}/bgfx.cmake/bgfx/3rdparty/meshoptimizer/src ${TP}/meshoptimizer-clusterlod)

add_library(tallow_collision_support OBJECT tallow_collision_profile.cpp tallow_overlap_contacts.cpp)
target_compile_features(tallow_collision_support PRIVATE cxx_std_17)
target_link_libraries(tallow_collision_support PRIVATE Jolt)

# Soft bodies (cloth, jelly) reach Jolt's C++ soft body settings, which joltc does not cover.
add_library(tallow_softbody OBJECT tallow_softbody.cpp)
target_compile_features(tallow_softbody PRIVATE cxx_std_17)
target_include_directories(tallow_softbody PRIVATE ${TP}/joltc/include)
target_link_libraries(tallow_softbody PRIVATE Jolt)
# Jolt is built without RTTI; classes derived from its own (GroupFilter) must be too.
if(MSVC)
	target_compile_options(tallow_softbody PRIVATE /GR-)
else()
	target_compile_options(tallow_softbody PRIVATE -fno-rtti)
endif()

# ---- Opus (voice chat codec), compiled into the shim so there is no extra archive to link ----
set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
if(MSVC)
	set(OPUS_STATIC_RUNTIME ON CACHE BOOL "" FORCE)
endif()
if(MSVC AND CMAKE_C_COMPILER_ID MATCHES "Clang")
	# Opus leaves out the per-file SSE4.1/AVX2 switches for Microsoft's compiler, and clang-cl needs them.
	set(OPUS_DISABLE_INTRINSICS ON CACHE BOOL "" FORCE)
endif()
add_subdirectory(${TP}/opus opus EXCLUDE_FROM_ALL)

# ---- Flecs v4.2.0 (entity component system), vendored single-file distribution ----
# A custom build with only the addons Tallow uses. The Explorer's addons (REST, HTTP, stats, JSON) are built in
# by default: they do nothing until something starts the server (the editor's Window > Flecs Explorer). Configure
# with -DTALLOW_FLECS_EXPLORER=OFF to leave them out.
add_library(tallow_flecs OBJECT tallow_flecs.c)
target_include_directories(tallow_flecs PRIVATE ${TP}/flecs)
target_compile_definitions(tallow_flecs PRIVATE FLECS_CUSTOM_BUILD FLECS_SYSTEM FLECS_PIPELINE FLECS_META FLECS_OS_API_IMPL FLECS_LOG
	FLECS_CACHED_QUERIES FLECS_QUERY_PLANS FLECS_PREFAB FLECS_FRAME)
if(TALLOW_FLECS_EXPLORER)
	target_compile_definitions(tallow_flecs PRIVATE FLECS_REST FLECS_HTTP FLECS_STATS FLECS_JSON)
endif()
if(NOT MSVC)
	target_compile_options(tallow_flecs PRIVATE -std=gnu99)
endif()

# The desktop engine starts .NET itself (hostfxr). In a browser the page starts .NET, whose start-up registers the
# managed entrypoints with the same host (tn_csharp_web_register), so web builds compile it too.
set(TALLOW_MANAGED_HOST_SOURCE tallow_dotnet_host.cpp)

# ---- Rapier3D (optional, prebuilt C bindings) ----
# The archive is built by tools/build_rapier.py and kept under third_party/rapier/prebuilt/<platform>. Normal builds
# never run Rust. Without an archive for this target the stub keeps every symbol the Beef provider links, reports
# tn_rapier_available() = 0, and the provider stays unlisted.
option(TALLOW_RAPIER "Link the Rapier3D C bindings when the prebuilt archive for this target is present" ON)
set(TALLOW_RAPIER_AVAILABLE OFF)
set(TALLOW_RAPIER_SOURCE tallow_rapier_stub.c)
set(TALLOW_RAPIER_LIBRARY "")
if(TALLOW_RAPIER)
	if(EMSCRIPTEN)
		set(_tallow_rapier_platform "web-wasm32")
		set(_tallow_rapier_library "librapier3d_ffi.a")
	elseif(ANDROID)
		# arm64-v8a (phones and tablets) or x86_64 (the emulator).
		set(_tallow_rapier_platform "android-${ANDROID_ABI}")
		set(_tallow_rapier_library "librapier3d_ffi.a")
	elseif(IOS)
		# iphoneos-arm64 (devices) or iphonesimulator-<arch> (the Simulator).
		if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
			set(_tallow_rapier_platform "iphonesimulator-${CMAKE_OSX_ARCHITECTURES}")
		else()
			set(_tallow_rapier_platform "iphoneos-${CMAKE_OSX_ARCHITECTURES}")
		endif()
		set(_tallow_rapier_library "librapier3d_ffi.a")
	elseif(WIN32)
		set(_tallow_rapier_platform "windows-x86_64")
		set(_tallow_rapier_library "rapier3d_ffi.lib")
	elseif(APPLE)
		if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64" OR (NOT CMAKE_OSX_ARCHITECTURES AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64"))
			set(_tallow_rapier_platform "macos-arm64")
		else()
			set(_tallow_rapier_platform "macos-x86_64")
		endif()
		set(_tallow_rapier_library "librapier3d_ffi.a")
	else()
		set(_tallow_rapier_platform "linux-x86_64")
		set(_tallow_rapier_library "librapier3d_ffi.a")
	endif()
	set(_tallow_rapier_dir ${TP}/rapier/prebuilt/${_tallow_rapier_platform})
	if(EXISTS ${_tallow_rapier_dir}/${_tallow_rapier_library})
		set(TALLOW_RAPIER_AVAILABLE ON)
		set(TALLOW_RAPIER_SOURCE tallow_rapier.cpp)
		file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/rapier)
		file(COPY ${_tallow_rapier_dir}/${_tallow_rapier_library} DESTINATION ${CMAKE_BINARY_DIR}/rapier)
		set(TALLOW_RAPIER_LIBRARY ${CMAKE_BINARY_DIR}/rapier/${_tallow_rapier_library})
		message(STATUS "Rapier3D: linking ${_tallow_rapier_dir}/${_tallow_rapier_library}")
	else()
		message(STATUS "Rapier3D: no archive for ${_tallow_rapier_platform}; the provider stays unlisted")
		# The Beef link lists, packaging and exported games name build/native[-win]/rapier/<archive> on every
		# desktop build. Without an archive, an empty one with the same name keeps them valid (the stub above
		# supplies the symbols). It is written now rather than built, so a build of just tallow_native (CI,
		# package_engine.py) has it too; GNU ld, lld and lld-link accept an archive with no members. The signature
		# must end in a bare LF: file(WRITE) gives CRLF on Windows, which lld-link rejects as an unknown file type.
		if(APPLE)
			# Apple's linker is not known to take an archive with no members: give it one holding a single object.
			file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/rapier)
			file(WRITE ${CMAKE_BINARY_DIR}/rapier/stand_in.c "int tallow_rapier_stand_in;\n")
			# For the target's processor and SDK (an iOS build is not for the Mac it is made on).
			set(_tallow_stand_in_flags "")
			foreach(_tallow_arch IN LISTS CMAKE_OSX_ARCHITECTURES)
				list(APPEND _tallow_stand_in_flags -arch ${_tallow_arch})
			endforeach()
			if(CMAKE_OSX_SYSROOT)
				list(APPEND _tallow_stand_in_flags -isysroot ${CMAKE_OSX_SYSROOT})
			endif()
			execute_process(COMMAND ${CMAKE_C_COMPILER} ${_tallow_stand_in_flags} -c ${CMAKE_BINARY_DIR}/rapier/stand_in.c -o ${CMAKE_BINARY_DIR}/rapier/stand_in.o
				RESULT_VARIABLE _tallow_stand_in_compiled)
			file(REMOVE ${CMAKE_BINARY_DIR}/rapier/${_tallow_rapier_library})
			execute_process(COMMAND ${CMAKE_AR} rcs ${CMAKE_BINARY_DIR}/rapier/${_tallow_rapier_library} ${CMAKE_BINARY_DIR}/rapier/stand_in.o
				RESULT_VARIABLE _tallow_stand_in_archived)
			if(NOT _tallow_stand_in_compiled EQUAL 0 OR NOT _tallow_stand_in_archived EQUAL 0)
				message(FATAL_ERROR "Could not make the stand-in Rapier archive for macOS")
			endif()
		else()
			file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/rapier/${_tallow_rapier_library} CONTENT "!<arch>\n" @ONLY
				NEWLINE_STYLE UNIX)
		endif()
	endif()
endif()

# ---- Tallow shim: Dear ImGui (docking) + ImGuizmo + stb_image + cgltf ----
add_library(tallow_native STATIC
	${TP}/cimgui/cimgui.cpp
	${TP}/cimgui/imgui/imgui.cpp
	${TP}/cimgui/imgui/imgui_draw.cpp
	${TP}/cimgui/imgui/imgui_tables.cpp
	${TP}/cimgui/imgui/imgui_widgets.cpp
	${TP}/cimgui/imgui/imgui_demo.cpp
	${TP}/cimgui/imgui/backends/imgui_impl_sdl3.cpp
	${TP}/ImGuizmo/src/ImGuizmo.cpp
	${TP}/TextEdit/TextEditor.cpp
	${TP}/TextEdit/extras/TrieAutoComplete.cpp
	tallow_native.cpp
	tallow_text.c
	tallow_code.cpp
	${TALLOW_MANAGED_HOST_SOURCE}
	tallow_bake.cpp
	tallow_skybox.cpp
	tallow_upscale.cpp
	tallow_rig.cpp
	tallow_assets.c
	tallow_modelimport.c
	tallow_pack.c
	tallow_guard.c
	tallow_physics.cpp
	${TALLOW_RAPIER_SOURCE}
	$<TARGET_OBJECTS:tallow_navigation>
	$<TARGET_OBJECTS:tallow_clusterlod>
	$<TARGET_OBJECTS:tallow_collision_support>
	$<TARGET_OBJECTS:tallow_softbody>
	$<TARGET_OBJECTS:tallow_flecs>
	tallow_audio.c
	tallow_web.c
	tallow_http.c
	tallow_network.c
	$<TARGET_OBJECTS:opus>
)
add_dependencies(tallow_native Jolt)
target_compile_features(tallow_native PRIVATE cxx_std_20)
target_include_directories(tallow_native PRIVATE
	${TP}/enet/include
	${TP}/cimgui
	${TP}/cimgui/imgui
	${TP}/cimgui/imgui/backends
	${TP}/ImGuizmo/src
	${TP}/TextEdit
	${TP}/stb
	${TP}/miniaudio
	${TP}/opus/include
	${TP}/cgltf
	${TP}/joltc/include
	${TP}/bgfx.cmake/bgfx/examples/common/imgui
	${TP}/bgfx.cmake/bimg/include
	${TP}/bgfx.cmake/bimg/3rdparty/tinyexr
)
target_compile_definitions(tallow_native PRIVATE
	IMGUI_DISABLE_OBSOLETE_FUNCTIONS=1
	"IMGUI_IMPL_API=extern \"C\""
)
if(TALLOW_RAPIER_AVAILABLE)
	target_compile_definitions(tallow_native PRIVATE RAPIER_STATIC RAPIER_DIM3 RAPIER_F32)
	target_include_directories(tallow_native PRIVATE ${_tallow_rapier_dir}/include)
endif()
target_link_libraries(tallow_native PRIVATE bgfx bx SDL3::SDL3-static)

# ---- DLSS and FSR (tallow_upscale.cpp): Vulkan renderer on Linux and Windows x86-64 ----
# DLSS comes from NVIDIA's SDK (downloaded and hash-checked at configure time, see FetchDLSS.cmake: its licence does
# not allow checking it into this open source repository). FSR is AMD's MIT-licensed FSR 2.2.1 temporal upscaler, with
# its Vulkan backend and pre-built shader permutations in third_party/fsr2.
if(NOT EMSCRIPTEN AND NOT ANDROID AND NOT IOS AND NOT APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
	set(_upscale_vk ${CMAKE_CURRENT_SOURCE_DIR}/upscale/vk)
	target_include_directories(tallow_native PRIVATE ${_upscale_vk})
	# tallow_upscale.cpp compiles its Vulkan code only where this is set; elsewhere it holds stubs.
	target_compile_definitions(tallow_native PRIVATE TALLOW_UPSCALE_VULKAN=1)
	option(TALLOW_DLSS "Build NVIDIA DLSS support (downloads the DLSS SDK)" ON)
	if(TALLOW_DLSS)
		include(${CMAKE_CURRENT_SOURCE_DIR}/FetchDLSS.cmake)
	endif()
	if(TALLOW_DLSS AND TALLOW_DLSS_AVAILABLE)
		get_filename_component(_dlss_runtime_dir ${TALLOW_DLSS_RUNTIME} DIRECTORY)
		target_compile_definitions(tallow_native PRIVATE TALLOW_HAVE_DLSS=1 "TALLOW_DLSS_RUNTIME_DIR=\"${_dlss_runtime_dir}\"")
		target_include_directories(tallow_native PRIVATE ${TALLOW_DLSS_DIR}/include)
		# The NGX helper objects go into tallow_native's own archive so no link line has to change (the Beef projects
		# list the archives by name). llvm-ar reads both the Linux .a and the Windows .lib.
		find_program(_ngx_ar NAMES llvm-ar ar)
		set(_ngx_objdir ${CMAKE_BINARY_DIR}/sdk/ngx-objects)
		file(MAKE_DIRECTORY ${_ngx_objdir})
		if(_ngx_ar AND NOT EXISTS ${_ngx_objdir}/.extracted)
			execute_process(COMMAND ${_ngx_ar} x ${TALLOW_DLSS_LIB} WORKING_DIRECTORY ${_ngx_objdir} RESULT_VARIABLE _ar_result)
			if(_ar_result EQUAL 0)
				file(WRITE ${_ngx_objdir}/.extracted "")
			endif()
		endif()
		file(GLOB _ngx_objects ${_ngx_objdir}/*.o ${_ngx_objdir}/*.obj)
		set_source_files_properties(${_ngx_objects} PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
		target_sources(tallow_native PRIVATE ${_ngx_objects})
		if(NOT WIN32)
			target_link_libraries(tallow_native PRIVATE ${CMAKE_DL_LIBS})
		endif()
		set(TALLOW_DLSS_RUNTIME_FILE ${TALLOW_DLSS_RUNTIME} CACHE INTERNAL "DLSS runtime a game ships next to its executable")
	endif()
	set(_fsr2 ${TP}/fsr2)
	add_library(tallow_fsr2 OBJECT
		${_fsr2}/ffx-fsr2-api/ffx_assert.cpp
		${_fsr2}/ffx-fsr2-api/ffx_fsr2.cpp
		${_fsr2}/ffx-fsr2-api/vk/ffx_fsr2_vk.cpp
		${_fsr2}/ffx-fsr2-api/vk/shaders/ffx_fsr2_shaders_vk.cpp)
	target_compile_features(tallow_fsr2 PRIVATE cxx_std_17)
	if(NOT MSVC)
		target_compile_definitions(tallow_fsr2 PRIVATE FFX_GCC=1)
		target_compile_definitions(tallow_native PRIVATE FFX_GCC=1)
	endif()
	target_include_directories(tallow_fsr2 PRIVATE ${_upscale_vk} ${_fsr2}/ffx-fsr2-api ${_fsr2}/shaders_vk)
	target_compile_definitions(tallow_fsr2 PRIVATE TALLOW_FSR2_RENAME_VK=1 _UNICODE UNICODE)
	if(NOT MSVC)
		target_compile_options(tallow_fsr2 PRIVATE -w -include ${CMAKE_CURRENT_SOURCE_DIR}/upscale/fsr2_compat.h)
	endif()
	set_target_properties(tallow_fsr2 PROPERTIES POSITION_INDEPENDENT_CODE ON)
	target_sources(tallow_native PRIVATE $<TARGET_OBJECTS:tallow_fsr2>)
	target_compile_definitions(tallow_native PRIVATE TALLOW_HAVE_FSR2=1)
	target_include_directories(tallow_native PRIVATE ${_fsr2}/ffx-fsr2-api)
endif()
if(IOS)
	# miniaudio reaches iOS's audio session through AVFoundation, which only Objective-C can include.
	set_source_files_properties(tallow_audio.c PROPERTIES COMPILE_OPTIONS "-xobjective-c;-fobjc-arc")
endif()


# ---- Model import settings step (tallowengine.com/docs/model-import), for Tallow.Build export ----
if(NOT EMSCRIPTEN AND NOT ANDROID AND NOT IOS)
	add_executable(tallow_modelsettings tallow_modelsettings.c tallow_modelimport.c)
	target_include_directories(tallow_modelsettings PRIVATE ${TP}/cgltf)
	if(NOT MSVC)
		target_link_libraries(tallow_modelsettings PRIVATE m)
	endif()
endif()

# ---- Model converter (editor tool): FBX, OBJ, DAE, STL, PLY and 3DS to .glb, through Assimp ----
# The editor and Tallow.Build export run tallow_modelconv as a program of its own (tallowengine.com/docs/model-import); games
# never link Assimp.
if(NOT EMSCRIPTEN AND NOT ANDROID AND NOT IOS)
	set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
	set(ASSIMP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
	set(ASSIMP_BUILD_ASSIMP_TOOLS OFF CACHE BOOL "" FORCE)
	set(ASSIMP_BUILD_SAMPLES OFF CACHE BOOL "" FORCE)
	set(ASSIMP_BUILD_DOCS OFF CACHE BOOL "" FORCE)
	set(ASSIMP_INSTALL OFF CACHE BOOL "" FORCE)
	set(ASSIMP_WARNINGS_AS_ERRORS OFF CACHE BOOL "" FORCE)
	set(ASSIMP_BUILD_USE_CCACHE OFF CACHE BOOL "" FORCE)
	set(ASSIMP_INJECT_DEBUG_POSTFIX OFF CACHE BOOL "" FORCE)
	# Its own zlib, so the tool needs nothing installed on the machine it runs on. Every Mac has zlib, and Assimp's
	# copy does not compile against current macOS SDKs (its zutil.h defines fdopen away when TARGET_OS_MAC is set).
	if(APPLE)
		set(ASSIMP_BUILD_ZLIB OFF CACHE BOOL "" FORCE)
	else()
		set(ASSIMP_BUILD_ZLIB ON CACHE BOOL "" FORCE)
	endif()
	set(ASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT OFF CACHE BOOL "" FORCE)
	set(ASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT OFF CACHE BOOL "" FORCE)
	# The glTF exporter shares code with the glTF importer, so that is built too.
	foreach(format FBX OBJ COLLADA STL PLY 3DS GLTF)
		set(ASSIMP_BUILD_${format}_IMPORTER ON CACHE BOOL "" FORCE)
	endforeach()
	set(ASSIMP_BUILD_GLTF_EXPORTER ON CACHE BOOL "" FORCE)
	add_subdirectory(${TP}/assimp assimp EXCLUDE_FROM_ALL)
	add_executable(tallow_modelconv tallow_modelconv.cpp)
	target_compile_features(tallow_modelconv PRIVATE cxx_std_17)
	target_link_libraries(tallow_modelconv PRIVATE assimp)
endif()
