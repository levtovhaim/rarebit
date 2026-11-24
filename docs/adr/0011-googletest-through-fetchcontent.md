# 0011. Test C++ with GoogleTest, fetched by CMake and pinned by hash

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The C++ libraries need unit tests that report per test through CTest (CLAUDE.md → Conventions) on three operating systems. The repo has no C++ dependency manager, and one test-only dependency doesn't justify adding one. CLAUDE.md rule 4 requires every dependency to be pinned.

## Decision

- Tests use **GoogleTest**, registered with CTest through `gtest_discover_tests`.
- It comes through **CMake `FetchContent`** (`native/cmake/googletest.cmake`):
  - pinned to the **uploaded release asset** by URL and `URL_HASH SHA256`;
  - its headers marked `SYSTEM`, so our warnings-as-errors don't apply to them;
  - kept out of installs.
- It is fetched only when tests are built (`RAREBIT_BUILD_TESTS`).
- Version bumps follow the dependency-versioning skill: the newest release at least 7 days old, URL and hash changed together, in a `chore(deps)` PR.

## Alternatives considered

| Option | Why not |
|---|---|
| Catch2 or doctest | Fine frameworks. GoogleTest is the most common one, integrates with CTest out of the box, and gives the build-cache experiments a real fetched dependency. |
| vcpkg or Conan now | A dependency manager for one test-only dependency; decide when the native code needs runtime dependencies |
| Plain test executables with asserts | No dependency, but poor failure messages and no per-test reporting in CTest |
| GitHub's generated source archive | Its bytes, and so its hash, can change; an uploaded release asset doesn't |
| A system-installed GoogleTest | A different version on every machine |

## Consequences

- **Good:** the same test framework bytes on every machine; a swapped download fails the configure step; per-test results in CTest.
- **Bad / risks:** configuring tests needs network access to GitHub (CI caches it later).
- **Follow-ups:** a dependency-manager ADR when runtime dependencies appear.

## How we'll know it was right

Bumps stay one-line PRs (URL and hash), and no CI failure traces back to a different GoogleTest than the pinned one.
