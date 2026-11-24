# hebrew-normalize: Hebrew normalization and answer matching, a static library with a C API.
add_library(
  hebrew_normalize STATIC
  src/c_api.cpp
  src/match.cpp
  src/normalize.cpp
  src/unicode.cpp
  src/utf8.cpp)
add_library(rarebit::hebrew_normalize ALIAS hebrew_normalize)

target_include_directories(
  hebrew_normalize
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include> $<INSTALL_INTERFACE:include>
  PRIVATE src)
target_compile_features(hebrew_normalize PUBLIC cxx_std_20)
target_compile_definitions(hebrew_normalize PRIVATE HN_VERSION="${PROJECT_VERSION}")
# Position-independent code, so the archive can be linked into a Go (cgo) binary built as PIE.
set_target_properties(hebrew_normalize PROPERTIES POSITION_INDEPENDENT_CODE ON)
rarebit_compile_options(hebrew_normalize)

# `cmake --install` puts the archive and the headers in a prefix, e.g. for an image build.
include(GNUInstallDirs)
install(TARGETS hebrew_normalize ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(RAREBIT_BUILD_TESTS)
  add_subdirectory(tests)
endif()
