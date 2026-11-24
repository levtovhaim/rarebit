# Native (C++) code: the Hebrew normalization library, and later the command-line tool.
# Build with the presets in CMakePresets.json, or `make native` from the repo root.
cmake_minimum_required(VERSION 3.28)

project(
  rarebit_native
  VERSION 0.1.0
  DESCRIPTION "Hebrew normalization and matching for Rarebit"
  LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Tests are off unless asked for (the presets ask), so a plain build, e.g. inside an image, needs
# no network: only the tests download GoogleTest.
option(RAREBIT_BUILD_TESTS "Build the unit tests (downloads GoogleTest)" OFF)
option(RAREBIT_WERROR "Treat compiler warnings as errors" ON)
option(RAREBIT_SANITIZE "Build everything with AddressSanitizer and UndefinedBehaviorSanitizer (GCC, Clang)" OFF)

include(cmake/compile-options.cmake)

# Sanitizers go on every target, the test framework included, or the runtime reports false
# positives at the boundary between instrumented and uninstrumented code.
if(RAREBIT_SANITIZE)
  if(MSVC)
    message(FATAL_ERROR "RAREBIT_SANITIZE is for GCC and Clang")
  endif()
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all)
  add_link_options(-fsanitize=address,undefined)
endif()

if(RAREBIT_BUILD_TESTS)
  enable_testing()
  include(cmake/googletest.cmake)
endif()

add_subdirectory(hebrew-normalize)
