# 0009. C++20 with CMake presets, a C API at the boundary, and GoogleTest pinned by hash

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

`native/` holds C++ that must build and test the same way on Linux (GCC), Windows (MSVC) and macOS (Clang), locally and in CI. It's consumed from Go through cgo, and later by a command-line tool. Its tests need a framework, and the repo has no C++ dependency manager.

## Decision

- **Language:** C++20, no compiler extensions, warnings as errors (`RAREBIT_WERROR`).
- **Build:** CMake 4.5 and Ninja from `.mise.toml`, driven by `native/CMakePresets.json`:
  - `linux-gcc`;
  - `linux-gcc-asan` (AddressSanitizer + UndefinedBehaviorSanitizer);
  - `macos-clang`;
  - `windows-msvc` (Visual Studio 2022 generator).
  `make native` picks the preset for the current OS. The compiler is an OS package.
- **Boundary:** each library is a static, position-independent archive with a C API (`extern "C"`, snprintf-style buffers, no exceptions across the boundary), so cgo links it without C++ name mangling.
- **Tests:** GoogleTest v1.18.0 through CMake `FetchContent`, pinned to the uploaded release asset by URL and SHA-256 (CLAUDE.md rule 4). Tests are registered with CTest through `gtest_discover_tests`.

## Alternatives considered

| Option | Why not |
|---|---|
| Catch2 or doctest | Fine frameworks; GoogleTest is the most common one, integrates with CTest out of the box, and gives the build-cache experiments a real fetched dependency |
| A dependency manager now (vcpkg or Conan) | One test-only dependency doesn't justify one yet. Decide when the native code needs runtime dependencies. |
| Plain test executables with asserts | No framework to fetch, but poor failure messages and no per-test reporting in CTest |
| GitHub's generated source archive for GoogleTest | Its bytes, and so its hash, can change; the uploaded release asset doesn't |
| A C++ API across cgo | cgo calls C; C++ symbols would need a C shim anyway |

## Consequences

- **Good:** one command per OS, reproducible dependency bytes, and sanitizer coverage on Linux. The C boundary also suits any other caller.
- **Bad / risks:**
  - configure needs network access to fetch GoogleTest (CI caches it later);
  - the macOS and Windows presets are defined but verified only once the CI matrix runs them;
  - a dependency bump means changing the URL and the hash together.
- **Follow-ups:**
  - the CI build matrix (GCC, MSVC, Clang) with compiler and dependency caches;
  - a dependency-manager ADR when runtime dependencies appear.

## How we'll know it was right

`make native` is green on all three operating systems in CI, and dependency bumps are one-line PRs with a hash.
