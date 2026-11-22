cmake_minimum_required(VERSION 3.16)
project(mars_farming LANGUAGES CXX)

# This file builds only the pure C++ farm simulation in core/ and its tests.
# The Godot extension (src/) is built with SCons, see README.md.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(FARM_BUILD_TESTS "Build the farm core test suite" ON)

if(FARM_BUILD_TESTS)
    enable_testing()
    add_executable(farm_tests
        tests/test_main.cpp
        tests/test_species.cpp
        tests/test_plant.cpp
        tests/test_bay.cpp)
    target_include_directories(farm_tests PRIVATE core)
    if(MSVC)
        target_compile_options(farm_tests PRIVATE /W4 /permissive- /utf-8)
    else()
        target_compile_options(farm_tests PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion)
    endif()
    add_test(NAME farm_tests COMMAND farm_tests)
endif()
