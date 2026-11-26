# 0030. Write rarebit-cli in C++, judging answers offline with the validator's rules

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

`rarebit-cli` is the developers' and operators' tool (CLAUDE.md → Architecture): check a word the way the game would, see how an answer normalizes, and run the bots against a stack. It ships as signed binaries for Linux, Windows and macOS (later, with the release pipeline). It needs the normalization library (`native/hebrew-normalize`, a C++ static archive with a C API, ADRs 0009–0011), and its `check` must agree with the validator exactly, or it's worse than no tool.

## Decision

- **C++20, in `native/rarebit-cli`,** built by the same CMake presets as the library (`make native`), linking the library directly. On Linux with GCC the C++ runtime is linked in statically (`-static-libstdc++ -static-libgcc`), so one binary runs on any distribution with a recent glibc.
- **`check` judges offline,** from the word-list files (`data/categories`), with the validator's steps and thresholds:
  - the letter and length checks;
  - an exact key;
  - a spelling variant (3+ letters);
  - a one-edit typo among the first 500 candidates of similar length (4+ letters).

  Each entry's keys are computed as the validator's content load computes them. The output is the validator's JSON body, and a parity test checks the two agree (`tests/parity.sh`: 9,053 answers, all identical).
- **No JSON dependency:** a small strict reader (RFC 8259) for our own files, plus the string escaping Go's `encoding/json` uses, so the output matches byte for byte.
- **`bots` runs the bots image with `docker run`** (read-only, no capabilities, on the local stack's network through its nginx by default), instead of reimplementing the protocol client. On Windows it starts docker with `CreateProcessW` and a command line quoted by the C runtime's rules; on Linux and macOS with `posix_spawnp`. Ctrl-C reaches the bots, which finish as they choose, and the CLI exits with their code.
- **Off by default in CMake** (`RAREBIT_BUILD_CLI`); the presets turn it on. The validator image's build of the library compiles nothing new.

## Alternatives considered

| Option | Why not |
|---|---|
| Go with cgo (the validator's stack) | The validator's code could be shared, and Go makes process handling easy. But cgo cross-compiling for Windows and macOS needs a C toolchain per target anyway, and the point of the native code is to exercise GCC, MSVC and Clang directly (the CI runner evaluation's heavy-build case). |
| `check` calling the validator's API | Always the same answer by definition, but it needs a running stack and a reachable validator, which doesn't publish a port; an offline check works anywhere, and the parity test keeps the two together. |
| nlohmann/json (FetchContent, pinned) | A well-tested parser, but one more dependency to pin, age-check and update for files we write ourselves; and Go-compatible output escaping would still be ours. |
| A bots runner that spawns Node and `apps/bots` directly | Needs Node and a build on every machine; the image is what CI and the cluster run. |

## Consequences

- **Good:**
  - one static-ish binary per OS, with no runtime dependency for `check` and `normalize`;
  - the same normalization code as the validator, so a key never differs;
  - the parity test catches a rule changed on one side only.
- **Bad / risks:**
  - **The rules exist twice** (`apps/validator/internal/validate` and `src/wordlist.cpp`). A change to one needs the same change to the other. The parity test fails until it's made, but only when someone runs it: it needs the local stack, so it isn't in `make check`.
  - **Ties break differently in principle:** the validator picks among entries with the same key by Postgres' collation, the CLI by bytes. On today's lists the parity test found no answer where that changes the reported entry, and it never changes the verdict.
  - **Windows and macOS builds aren't verified yet** (no MSVC or Clang here); the CI matrix builds them.
  - The bots runner needs Docker.

## How we'll know it was right

The parity test stays at zero differences as the lists and rules change, and the release pipeline builds and signs the binary on all three OSes without code changes.
