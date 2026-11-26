# rarebit-cli: a command-line tool for developers and operators. Checks answers offline against the
# word lists with the validator's rules, shows normalization keys, and runs the bots image.
# Everything but main() is a library, so the unit tests can call the commands directly.
add_library(
  rarebit_cli_core STATIC
  src/bots.cpp
  src/cli.cpp
  src/json.cpp
  src/process.cpp
  src/utf8.cpp
  src/wordlist.cpp)
target_include_directories(rarebit_cli_core PUBLIC src)
target_link_libraries(rarebit_cli_core PUBLIC hebrew_normalize)
target_compile_features(rarebit_cli_core PUBLIC cxx_std_20)
target_compile_definitions(rarebit_cli_core PRIVATE RAREBIT_CLI_VERSION="${PROJECT_VERSION}")
rarebit_compile_options(rarebit_cli_core)

add_executable(rarebit-cli src/main.cpp)
target_link_libraries(rarebit-cli PRIVATE rarebit_cli_core)
rarebit_compile_options(rarebit-cli)
# One binary that runs on any Linux with a recent enough glibc: the C++ runtime is linked in.
target_link_options(rarebit-cli PRIVATE
                    $<$<AND:$<PLATFORM_ID:Linux>,$<CXX_COMPILER_ID:GNU>>:-static-libstdc++;-static-libgcc>)

include(GNUInstallDirs)
install(TARGETS rarebit-cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

if(RAREBIT_BUILD_TESTS)
  add_subdirectory(tests)
endif()
