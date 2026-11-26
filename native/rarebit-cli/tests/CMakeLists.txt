add_executable(
  rarebit_cli_tests
  cli_test.cpp
  json_test.cpp
  process_test.cpp
  utf8_test.cpp
  wordlist_test.cpp)
target_link_libraries(rarebit_cli_tests PRIVATE rarebit_cli_core GTest::gtest_main)
target_compile_definitions(
  rarebit_cli_tests PRIVATE RAREBIT_CLI_TEST_DATA="${CMAKE_CURRENT_SOURCE_DIR}/data/categories"
                            RAREBIT_REPO_DATA="${PROJECT_SOURCE_DIR}/../data/categories")
rarebit_compile_options(rarebit_cli_tests)

include(GoogleTest)
gtest_discover_tests(rarebit_cli_tests DISCOVERY_MODE PRE_TEST)
