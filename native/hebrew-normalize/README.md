# hebrew-normalize

A small C++20 static library that turns a player's answer into a comparison key and decides whether it matches a word-list entry. It has no runtime dependencies. The Go validator calls it through cgo, and the command-line tool will too, so every component compares answers the same way.

## What it does

`normalize(answer)` builds the comparison key:

| Step | Example |
|---|---|
| Strip niqqud and cantillation marks | שָׁלוֹם → שלומ |
| Final letters as regular letters (ך→כ ם→מ ן→נ ף→פ ץ→צ) | ירושלים → ירושלימ |
| Drop spaces and punctuation, Hebrew ones included (maqaf, geresh, gershayim) | תל־אביב, צה״ל → תלאביב, צהל |
| Presentation forms and ligatures as plain letters (NFKD; the Yiddish ligatures spelled out) | U+FB2A → ש, U+05F0 → וו |
| Latin letters as lowercase ASCII, diacritics removed | Café → cafe |
| ASCII digits kept | iPhone 15 → iphone15 |
| Invalid UTF-8, other scripts and symbols dropped | |

The key holds only Hebrew letters, `a`–`z` and `0`–`9`. NFC and NFD input give the same key. That matters because macOS writes NFD in places, such as file names and some keyboards.

`spelling_key(answer)` is the key with the vav and yod letters that full spelling (ktiv male) adds removed between the first and last letter, and doubled vav/yod collapsed. So שולחן and שלחן get the same spelling key.

`match(answer, entry)` normalizes both and returns:

| Result | When |
|---|---|
| `exact` | the keys are equal |
| `variant` | the spelling keys are equal and both words have 3+ letters |
| `fuzzy` | both have 4+ letters and they're one edit apart (Levenshtein): a likely typo |
| `none` | anything else, including an empty answer |

`match_keys(answer_key, entry_key)` does the same comparison on two keys that `normalize()` already produced.

`variant` and `fuzzy` are heuristics: תפוז and תפוח are one edit apart. So a caller looks up in this order:
1. normalize the answer **once**;
2. look for an `exact` match: the key in an index of entry keys;
3. if there's none, look for entries with the same spelling key;
4. call `match_keys` only on the few remaining candidates, e.g. entries with the same first letter and a length within one.

`to_nfc()` and `to_nfd()` normalize Hebrew text (U+0590–U+05FF, U+FB1D–U+FB4F) to Unicode NFC and NFD; other code points pass through unchanged. Every precomposed Hebrew character is a composition exclusion, so for Hebrew NFC and NFD are the same string.

## Use it

- **C or cgo:** `include/hebrew_normalize/hebrew_normalize.h`.
  - Every function is pure and thread-safe, and never throws.
  - Output functions work like `snprintf`: they return the full length and write at most `out_cap - 1` bytes plus a NUL.
  - `HN_ERROR` (or `HN_MATCH_ERROR`) means an input over `HN_MAX_INPUT_BYTES` (4096), `in` was NULL with a length, or an allocation failed.
- **C++:** `include/hebrew_normalize/hebrew_normalize.hpp`, namespace `hebrew_normalize`. It has no size cap; the C API adds it.
- **Linking:** the archive is `libhebrew_normalize.a`. A C or Go program also links the C++ runtime: `-lhebrew_normalize -lstdc++ -lm` on Linux, `-lhebrew_normalize -lc++` on macOS (not verified yet). The code is position-independent, so it links into PIE binaries (ADR 0010).
- **Install** the archive and headers into a prefix. A plain configure builds no tests and needs no network, which suits an image build:

  ```bash
  cmake -S native -B /tmp/native-build -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build /tmp/native-build && cmake --install /tmp/native-build --prefix /opt/hebrew-normalize
  ```

### Calling it from Go

What the cgo wrapper has to get right:

- **Cap the answer before the call:** a few dozen characters is plenty for an answer. Also put a body limit on the request that carries it. The library refuses anything over 4096 bytes, but the caller shouldn't get that far.
- **Check the return value in order:**
  1. `HN_ERROR` first;
  2. then a return value `>= out_cap`, which means truncated: call again with a buffer of `ret + 1`.
  Size the first buffer generously: `normalize` can return up to 2× the input bytes and `to_nfd` up to 3×. A truncated buffer can end in the middle of a UTF-8 character.
- **Read with the returned length** (`C.GoStringN(out, C.int(ret))` once `ret < out_cap`), never `C.GoString`. `to_nfc`/`to_nfd` output passes NULs and control characters through unchanged.
- **Empty input:** pass `nil, 0`. `&b[0]` panics on an empty slice.
- **Reject an answer whose key is empty:** it was only punctuation, symbols or another script.
- **Use the key, not the raw text,** for lookups and for the offensive-word filter. On raw text, niqqud, zero-width characters and punctuation slip past a filter. Keep SQL parameterized anyway.

## Build and test

From the repository root, with the tools from `.mise.toml` and a C++ compiler from the OS:

```bash
make native                               # the preset for this OS
make native NATIVE_PRESET=linux-gcc-asan  # AddressSanitizer + UndefinedBehaviorSanitizer
```

The presets are in `native/CMakePresets.json`: `linux-gcc`, `linux-gcc-asan`, `macos-clang` and `windows-msvc` (Visual Studio 2022). On Windows without `make`, run from `native/`:

```bash
cmake --preset windows-msvc && cmake --build --preset windows-msvc && ctest --preset windows-msvc
```

Warnings are errors, and every build carries hardening flags (ADR 0009). The presets turn the tests on. The tests use GoogleTest, fetched at configure time from a URL pinned by SHA-256 (ADR 0011).

## Unicode data

`src/unicode_tables.inc` and `tests/data/unicode_vectors.tsv` are generated from the Unicode Character Database (Unicode 16.0.0, Unicode License v3) through Python's `unicodedata`:

```bash
python native/hebrew-normalize/tools/gen_unicode_data.py
```

- The output depends only on Python's Unicode version.
- The generator stops if a new Unicode version makes Hebrew NFC differ from NFD, because `to_nfc()` relies on that.
- The build checks that the tables are sorted and that their sequences fit, so a broken `.inc` file fails to compile.
- The vectors test compares `to_nfc()` and `to_nfd()` with Python on every Hebrew-scope code point and 600 random sequences.

Why there's no ICU: ADR 0008.
