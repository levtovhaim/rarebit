# GoogleTest for the native unit tests (ADR 0009).
# Pinned to an uploaded release asset by URL and SHA-256 (CLAUDE.md rule 4). GitHub's generated
# source archives aren't used: their bytes, and so their hashes, can change.
# To bump: follow .claude/skills/dependency-versioning, then change the URL and the hash together.
include(FetchContent)

set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
# MSVC: link the same C runtime as our targets.
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

FetchContent_Declare(
  googletest
  # v1.18.0, published 2026-08-10
  URL https://github.com/google/googletest/releases/download/v1.18.0/googletest-1.18.0.tar.gz
  URL_HASH SHA256=6e3191c1455468b3fc35a417fb565c1c5071aee1b7e7f85e30cf48a98d37d8b5
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  # Its headers count as system headers, so our -Werror doesn't fail on warnings inside them.
  SYSTEM
  EXCLUDE_FROM_ALL)

FetchContent_MakeAvailable(googletest)
