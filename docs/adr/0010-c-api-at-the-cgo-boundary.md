# 0010. Expose native libraries to Go through a C API on a static archive

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The Go validator calls `native/hebrew-normalize` through cgo, and other callers may follow (the command-line tool). cgo calls C, not C++: C++ symbols are mangled, exceptions can't cross into Go, and object lifetimes don't map onto Go's garbage collector. The validator ships as a distroless image, so how the library is linked decides what the image has to contain.

## Decision

- Each native library is a **static, position-independent archive** (`lib<name>.a`), so it links into a Go binary built as PIE, and the image carries no extra shared library.
- Its public interface for non-C++ callers is a **C API** (`extern "C"`):
  - inputs are pointer + length (no NUL scanning);
  - outputs go into caller buffers, snprintf-style: return the full length, write at most `out_cap - 1` bytes plus a NUL;
  - errors are return values (`HN_ERROR`, `HN_MATCH_ERROR`);
  - inputs are capped (`HN_MAX_INPUT_BYTES`);
  - no C++ exception crosses the boundary: every entry point catches.
- A C++ API sits beside it for C++ callers.
- What the caller must do (cap lengths, retry on truncation, read with the returned length) is written in the library's README.

## Alternatives considered

| Option | Why not |
|---|---|
| C++ API through a SWIG-style generated wrapper | Generated glue to review and update, for a handful of functions |
| A shared library (`.so`) | One more file in the image, plus a loader path to get right; nothing gains from sharing it |
| The library allocates the output and the caller frees it | A second allocator crossing the boundary, and a leak whenever Go forgets the free; caller buffers keep ownership in Go |
| Port the logic to Go | Two implementations to keep identical (the CLI is C++) |

## Consequences

- **Good:**
  - one implementation for every language;
  - the Go side owns all memory;
  - errors are explicit values;
  - a static link keeps the image to one binary.
- **Bad / risks:**
  - the caller must handle truncation and the size cap correctly;
  - a Go binary that links C++ also links the C++ runtime (`-lstdc++ -lm`), which matters for fully static builds.
- **Follow-ups:** the validator's cgo wrapper and its tests; the image build with static linking.

## How we'll know it was right

The validator calls the library with no crashes or leaks under load, and the image stays a single distroless binary.
