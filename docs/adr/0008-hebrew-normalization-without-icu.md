# 0008. Normalize Hebrew with generated Unicode tables, not ICU

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

Answers are compared after normalization: niqqud removed, final letters as regular ones, punctuation dropped, presentation forms and ligatures as plain letters, and NFC and NFD input treated alike (macOS writes NFD in places). The validator (Go, through cgo) and the command-line tool must normalize identically, so the logic lives in one C++ library, `native/hebrew-normalize`.

General Unicode normalization needs Unicode data: decompositions and combining classes. The question is where that data comes from. The validator ships as a distroless image with the library linked statically, so every dependency adds image size, build steps on three operating systems, and patching work.

## Decision

- The library covers the scope the game needs: the Hebrew block (U+0590–U+05FF), the Hebrew presentation forms (U+FB1D–U+FB4F), and folding Latin-1 Supplement and Latin Extended-A letters to ASCII.
- Its tables (canonical and compatibility decompositions, combining classes, Latin folds) are **generated** from the Unicode Character Database through Python's `unicodedata` by `tools/gen_unicode_data.py`, and committed together with the generator.
- The same generator writes test vectors: NFC and NFD of every code point in scope, plus 600 random Hebrew sequences, all computed by Python. The C++ tests must reproduce them.
- Every precomposed Hebrew character is a Unicode composition exclusion, so for Hebrew NFC equals NFD. `to_nfc()` relies on that, and the generator stops if a future Unicode version breaks it.

## Alternatives considered

| Option | Why not |
|---|---|
| ICU | Tens of megabytes of data, a heavy build on three OSes, harder static linking into a distroless image, and a CVE stream to follow, for a fraction of what it does |
| utf8proc (small C library, MIT) | Viable and covers every script, but it's a third-party dependency without a C++ dependency manager in the repo yet. It's the fallback if the scope grows. |
| Normalize in Go (`golang.org/x/text`) | Splits normalization across languages: the C++ command-line tool and the Go validator could disagree |

## Consequences

- **Good:**
  - no runtime dependencies, so static linking into the validator image stays trivial;
  - tables of about 300 lines;
  - correctness checked against an independent implementation (Python) on every build.
- **Bad / risks:**
  - only Hebrew and the Latin folds are normalized; other scripts pass through unchanged (NFC/NFD) or are dropped (comparison key);
  - a Unicode update means re-running the generator with a newer Python.
- **Follow-ups:** none planned. Revisit if answers in other scripts matter, or once a C++ dependency manager is chosen (then utf8proc is a small step).

## How we'll know it was right

The vectors test stays green, the validator image stays small, and no reported answer mismatch traces back to normalization of text outside the covered scope.
