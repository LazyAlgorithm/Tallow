# Cross-compiles the native libraries for 64-bit Windows from Linux: clang-cl and lld-link against the Microsoft
# C runtime and Windows SDK that `xwin` downloaded. TALLOW_WIN (an environment variable, or the default below)
# is the folder tools/windows/setup.sh filled.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)
if(DEFINED ENV{TALLOW_WIN})
	set(TALLOW_WIN "$ENV{TALLOW_WIN}")
else()
	set(TALLOW_WIN "$ENV{HOME}/.local/share/tallow-win")
endif()
set(XWIN "${TALLOW_WIN}/xwin")

set(CMAKE_C_COMPILER clang-cl)
set(CMAKE_CXX_COMPILER clang-cl)
set(CMAKE_C_COMPILER_TARGET x86_64-pc-windows-msvc)
set(CMAKE_CXX_COMPILER_TARGET x86_64-pc-windows-msvc)
set(CMAKE_LINKER "${TALLOW_WIN}/bin/lld-link")
set(CMAKE_AR llvm-lib)
set(CMAKE_RC_COMPILER llvm-rc)
set(CMAKE_MT llvm-mt)
# Beef links its Windows programs against the static C runtime; so must everything linked into them.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)

set(includes "-imsvc ${XWIN}/crt/include -imsvc ${XWIN}/sdk/include/ucrt -imsvc ${XWIN}/sdk/include/um -imsvc ${XWIN}/sdk/include/shared -imsvc ${XWIN}/sdk/include/winrt")
set(CMAKE_C_FLAGS_INIT "${includes}")
set(CMAKE_CXX_FLAGS_INIT "${includes} /EHsc")
set(CMAKE_RC_FLAGS_INIT "-I ${XWIN}/crt/include -I ${XWIN}/sdk/include/ucrt -I ${XWIN}/sdk/include/um -I ${XWIN}/sdk/include/shared")
set(libs "/libpath:${XWIN}/crt/lib/x86_64 /libpath:${XWIN}/sdk/lib/um/x86_64 /libpath:${XWIN}/sdk/lib/ucrt/x86_64")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${libs}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${libs}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${libs}")
# Only static libraries are built, so compiler checks need not link a program.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH "${XWIN}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
