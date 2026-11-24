add_executable(
  hebrew_normalize_tests
  c_api_test.cpp
  match_test.cpp
  normalize_test.cpp
  unicode_vectors_test.cpp
  utf8_test.cpp)
target_link_libraries(hebrew_normalize_tests PRIVATE hebrew_normalize GTest::gtest_main)
# The tests also exercise the internal code-point helpers.
target_include_directories(hebrew_normalize_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)
target_compile_definitions(hebrew_normalize_tests PRIVATE HN_TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/data")
rarebit_compile_options(hebrew_normalize_tests)

include(GoogleTest)
gtest_discover_tests(hebrew_normalize_tests DISCOVERY_MODE PRE_TEST)
