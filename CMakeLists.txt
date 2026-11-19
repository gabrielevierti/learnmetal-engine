# The C++ version of the LearnMetal Engine, and the Marble sample game.
#
#   cmake -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
#   ./build/marble
#   ./build/editor demo
#
# The four libraries it uses are downloaded by CMake the first time (see below).
cmake_minimum_required(VERSION 3.24)
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0 CACHE STRING "Oldest macOS the programs run on")
project(LearnMetalEngine LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "Metal only exists on Apple platforms: this project builds on macOS.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()

# ---------------------------------------------------------------- dependencies
include(FetchContent)

# GLFW: the window, keyboard, mouse and gamepads.
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(glfw GIT_REPOSITORY https://github.com/glfw/glfw.git GIT_TAG 3.4 GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(glfw)

# metal-cpp: Apple's C++ interface to Metal. Apple publishes it as a download rather
# than a repository, so this fetches a mirror at a fixed commit. To use the copy from
# https://developer.apple.com/metal/cpp/ instead, pass -DLM_METAL_CPP_DIR=/path/to/metal-cpp.
set(LM_METAL_CPP_DIR "" CACHE PATH "A metal-cpp folder to use instead of downloading the mirror")
if(LM_METAL_CPP_DIR)
    set(metalcpp_SOURCE_DIR ${LM_METAL_CPP_DIR})
else()
    FetchContent_Declare(metalcpp GIT_REPOSITORY https://github.com/bkaradzic/metal-cpp.git
                         GIT_TAG 9a8bc57c0318b84863bec2faf6605594877c5f5d SOURCE_SUBDIR do-not-build)
    FetchContent_MakeAvailable(metalcpp)
endif()

# stb_image and stb_image_write: reading PNG and JPEG files, writing PNG files.
FetchContent_Declare(stb GIT_REPOSITORY https://github.com/nothings/stb.git
                     GIT_TAG 9600522de53973336fa033a289858a4354cbb04c SOURCE_SUBDIR do-not-build)
# miniaudio: sound output and audio file decoding.
FetchContent_Declare(miniaudio GIT_REPOSITORY https://github.com/mackron/miniaudio.git GIT_TAG 0.11.21 GIT_SHALLOW TRUE
                     SOURCE_SUBDIR do-not-build)
FetchContent_MakeAvailable(stb miniaudio)

# ---------------------------------------------------------------- the engine
file(GLOB_RECURSE LM_ENGINE_SOURCES CONFIGURE_DEPENDS Cpp/engine/*.cpp Cpp/engine/*.hpp)
add_library(lmengine STATIC ${LM_ENGINE_SOURCES} Cpp/engine/Platform/MetalLayerBridge.mm Shaders/Shared/ShaderTypes.h)
target_include_directories(lmengine PUBLIC Cpp/engine Shaders/Shared)
target_include_directories(lmengine SYSTEM PUBLIC ${metalcpp_SOURCE_DIR} ${stb_SOURCE_DIR} ${miniaudio_SOURCE_DIR})
# While developing, shaders and assets are read from this source tree (see Core/Paths.hpp).
target_compile_definitions(lmengine PRIVATE LM_SOURCE_ROOT="${CMAKE_SOURCE_DIR}")
target_compile_options(lmengine PRIVATE -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers)
set_source_files_properties(Cpp/engine/Platform/MetalLayerBridge.mm PROPERTIES COMPILE_OPTIONS -fobjc-arc)
target_link_libraries(lmengine PUBLIC glfw
    "-framework Metal" "-framework Foundation" "-framework QuartzCore" "-framework Cocoa"
    "-framework CoreAudio" "-framework AudioToolbox" "-framework AudioUnit" "-framework CoreFoundation")

# ---------------------------------------------------------------- the game
file(GLOB LM_MARBLE_SOURCES CONFIGURE_DEPENDS Cpp/marble/*.cpp Cpp/marble/*.hpp)
add_executable(marble ${LM_MARBLE_SOURCES})
target_link_libraries(marble PRIVATE lmengine)

# ---------------------------------------------------------------- FPV, the drone game
file(GLOB LM_FPV_SOURCES CONFIGURE_DEPENDS Cpp/fpv/*.cpp Cpp/fpv/*.hpp)
add_executable(fpv ${LM_FPV_SOURCES})
target_include_directories(fpv PRIVATE Cpp)
target_link_libraries(fpv PRIVATE lmengine)

# ---------------------------------------------------------------- the editor
file(GLOB LM_EDITOR_SOURCES CONFIGURE_DEPENDS Cpp/editor/*.cpp Cpp/editor/*.hpp)
add_executable(editor ${LM_EDITOR_SOURCES})
target_link_libraries(editor PRIVATE lmengine)

# ---------------------------------------------------------------- tests
#   ctest --test-dir build -L unit     the unit tests: no GPU needed
#   ctest --test-dir build -L gpu      the autopilot plays the whole course on the GPU, without a window
enable_testing()
file(GLOB LM_TEST_SOURCES CONFIGURE_DEPENDS Cpp/tests/*.cpp Cpp/tests/*.hpp)
add_executable(lmtests ${LM_TEST_SOURCES} Cpp/fpv/FlightModel.cpp Cpp/fpv/Track.cpp)
target_include_directories(lmtests PRIVATE Cpp)
target_link_libraries(lmtests PRIVATE lmengine)
add_test(NAME unit COMMAND lmtests)
set_tests_properties(unit PROPERTIES LABELS unit)
add_test(NAME marble-demo COMMAND marble --demo --capture ${CMAKE_BINARY_DIR}/marble-demo.png --frames 2400)
set_tests_properties(marble-demo PROPERTIES LABELS gpu TIMEOUT 600)
add_test(NAME editor-opens-demo COMMAND editor demo --capture ${CMAKE_BINARY_DIR}/editor-demo.png --frames 5)
set_tests_properties(editor-opens-demo PROPERTIES LABELS gpu TIMEOUT 600)
add_test(NAME fpv-starts-a-race COMMAND fpv --race --capture ${CMAKE_BINARY_DIR}/fpv-race.png --frames 240)
set_tests_properties(fpv-starts-a-race PROPERTIES LABELS gpu TIMEOUT 600)
