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
| Invalid UTF-8, other scripts and symbols dropped | |

NFC and NFD input give the same key. That matters because macOS writes NFD in places, such as file names and some keyboards.

`spelling_key(answer)` is the key with the vav and yod letters that full spelling (ktiv male) adds removed between the first and last letter, and doubled vav/yod collapsed. So שולחן and שלחן get the same spelling key.

`match(answer, entry)` returns:

| Result | When |
|---|---|
| `exact` | the keys are equal |
| `variant` | the spelling keys are equal and both words have 3+ letters |
| `fuzzy` | both have 4+ letters and they're one edit apart (Levenshtein): a likely typo |
| `none` | anything else, including an empty answer |

`variant` and `fuzzy` are heuristics: תפוז and תפוח are one edit apart. A caller checks for an `exact` match across **all** entries before it accepts a `variant` or `fuzzy` one.

`to_nfc()` and `to_nfd()` normalize Hebrew text (U+0590–U+05FF, U+FB1D–U+FB4F) to Unicode NFC and NFD; other code points pass through unchanged. Every precomposed Hebrew character is a composition exclusion, so for Hebrew NFC and NFD are the same string.

## Use it

- **C or cgo:** `include/hebrew_normalize/hebrew_normalize.h`. Output functions work like `snprintf`: they return the full length and write at most `out_cap - 1` bytes plus a NUL. `HN_ERROR` means memory ran out or `in` was NULL with a length. Every function is pure and thread-safe and never throws.
- **C++:** `include/hebrew_normalize/hebrew_normalize.hpp`, namespace `hebrew_normalize`.
- **Linking:** the archive is `libhebrew_normalize.a`. A C or Go program also links the C++ runtime: `-lhebrew_normalize -lstdc++ -lm`. The code is position-independent, so it links into PIE binaries.
- **Install** the archive and headers into a prefix, e.g. for an image build: `cmake --install native/build/linux-gcc --prefix /opt/hebrew-normalize`.

## Build and test

From the repository root, with the tools from `.mise.toml` and a C++ compiler from the OS:

```bash
make native                               # the preset for this OS: linux-gcc or macos-clang
make native NATIVE_PRESET=linux-gcc-asan  # AddressSanitizer + UndefinedBehaviorSanitizer
```

The presets are in `native/CMakePresets.json`: `linux-gcc`, `linux-gcc-asan`, `macos-clang` and `windows-msvc` (Visual Studio 2022; run `cmake --preset windows-msvc` from `native/`). Warnings are errors. The tests use GoogleTest (ADR 0009), fetched at configure time from a URL pinned by SHA-256.

## Unicode data

`src/unicode_tables.inc` and `tests/data/unicode_vectors.tsv` are generated from the Unicode Character Database (Unicode 16.0.0, Unicode License v3) through Python's `unicodedata`:

```bash
python native/hebrew-normalize/tools/gen_unicode_data.py
```

The output depends only on Python's Unicode version. The generator stops if a new Unicode version makes Hebrew NFC differ from NFD, because `to_nfc()` relies on that. The vectors test compares `to_nfc()` and `to_nfd()` with Python on every Hebrew-scope code point and 600 random sequences. Why there's no ICU: ADR 0008.
