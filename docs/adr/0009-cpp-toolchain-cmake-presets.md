# 0009. Build the C++ code as C++20 with CMake presets, one per OS

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

`native/` holds C++ that must build and test the same way on Linux (GCC), Windows (MSVC) and macOS (Clang), on developer machines and in CI. Each of those needs a generator, a compiler, a build type and flags; without one shared definition, every machine and CI job would spell them differently.

## Decision

- **Language:** C++20, no compiler extensions.
- **Tools:** CMake 4.5 and Ninja from `.mise.toml`. The compiler is an OS package (GCC, MSVC through Visual Studio 2022, Clang).
- **One definition of each build,** in `native/CMakePresets.json`:
  - `linux-gcc`;
  - `linux-gcc-asan`: AddressSanitizer + UndefinedBehaviorSanitizer, on every target including the test framework;
  - `macos-clang`;
  - `windows-msvc`: the Visual Studio 2022 generator.
  Each has matching build and test presets. `make native` picks the preset for the current OS; `NATIVE_PRESET` overrides it.
- **Flags** (`native/cmake/compile-options.cmake`):
  - warnings as errors (`RAREBIT_WERROR`);
  - hardening on every build: stack protector, standard-library assertions and stack-clash protection on Linux, `_FORTIFY_SOURCE=3` in optimized builds, `/sdl` and Control Flow Guard on MSVC.
- **Tests are opt-in** (`RAREBIT_BUILD_TESTS`, on in the presets), so a plain build, e.g. inside an image, needs no network.

## Alternatives considered

| Option | Why not |
|---|---|
| Build scripts per OS | Three ways to say the same thing, drifting apart; presets are read by CMake itself, IDEs and CI |
| C++17 | No reason to stay older: GCC 13, current MSVC and Clang all support C++20 (`std::span`, designated initializers) |
| Makefiles or Visual Studio solutions only | Not portable across the three operating systems |

## Consequences

- **Good:** one command per OS (`make native`, or the three `cmake --preset` steps on Windows); the same flags everywhere; sanitizer coverage on Linux.
- **Bad / risks:**
  - the macOS and Windows presets are defined but verified only once the CI matrix runs them;
  - `-Werror` can break a build when a compiler upgrade adds a warning. That's intended: the fix is a code change, not a weaker flag.
- **Follow-ups:** the CI build matrix (GCC, MSVC, Clang) with compiler caches; a fuzz target under the sanitizers once Clang is available in CI.

## How we'll know it was right

`make native` is green on all three operating systems in CI, and nobody needs a private build script.
