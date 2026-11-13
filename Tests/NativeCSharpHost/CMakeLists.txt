cmake_minimum_required(VERSION 3.20)
project(tallow_csharp_native_smoke LANGUAGES CXX)

add_executable(tallow_native_csharp_smoke
    main.cpp
    ../../native/tallow_dotnet_host.cpp
)
target_compile_features(tallow_native_csharp_smoke PRIVATE cxx_std_20)
target_include_directories(tallow_native_csharp_smoke PRIVATE ../../native)
if(UNIX AND NOT APPLE)
    target_link_libraries(tallow_native_csharp_smoke PRIVATE dl)
endif()
