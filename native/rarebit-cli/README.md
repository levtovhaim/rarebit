# rarebit-cli

A command-line tool for developers and operators ([ADR 0030](../../docs/adr/0030-rarebit-cli-in-cpp.md)): judge an answer the way the game would, see how an answer normalizes, and run the bots. C++20, linking [hebrew-normalize](../hebrew-normalize/README.md); built and tested by `make native` (it's in the CMake presets; plain `cmake` builds it with `-DRAREBIT_BUILD_CLI=ON`).

```bash
make native
cli=native/build/linux-gcc/rarebit-cli/rarebit-cli     # the preset's build directory

$cli check animal ג גירפא                 # valid: one-letter typo of "ג'ירפה"
$cli check --json city ת "תל אביב"        # the validator's JSON body
$cli normalize "תַּרְנְגוֹל"                     # key, spelling key, letters
$cli bots synthetic                       # the bots image plays a game on the local stack (make up)
$cli bots --url https://preview.example --network bridge synthetic --origin https://preview.example
$cli version
```

## Commands

| Command | Does | Exit |
|---|---|---|
| `check [--data DIR] [--json] <category> <letter> <answer>` | Judges an answer offline, from the word lists in `DIR` (default `data/categories`, so run it from the repo root), with the validator's rules. `--json` prints the validator's response body. | 0 valid, 1 invalid or unknown, 2 an unknown category or a letter a round can't use, 3 a word-list file that can't be read or breaks the data rules |
| `normalize [--json] <text>` | The comparison key, the spelling key and the key's length in letters. | 0 |
| `bots [--image I] [--network N] [--url U] [--origin O] [--dry-run] <mode> [bots options…]` | Runs the bots image with `docker run`: read-only, no capabilities, `--network rarebit_default`, `BOTS_URL=http://nginx:8080`, `BOTS_ORIGIN=http://localhost:8080` (the local stack), unless the options say otherwise. `<mode>` and everything after it go to the bots unchanged ([apps/bots](../../apps/bots/README.md)). `--dry-run` prints the docker command. | the bots' exit code; 127 Docker not found |
| `version` | The CLI's, the library's and Unicode's versions. | 0 |

Usage errors exit 2. `--` ends the options, for an answer that starts with `-`.

## How `check` matches the validator

The same steps and thresholds as `apps/validator/internal/validate`:
1. **Request checks:** a letter that isn't one of the 22 is an error. An answer over 64 characters is `too_long`. An answer with no letters is `empty`. One whose key doesn't start with the letter is `wrong_letter`.
2. **Exact:** the normalized key equals an entry's key (niqqud, final forms, spaces and punctuation don't count).
3. **Spelling variant** (keys of 3+ letters): the spelling keys match, so full and defective spelling count as the same word.
4. **Typo** (keys of 4+ letters): one edit away from an entry with the same first letter and a key one letter shorter to one longer, among the first 500 such entries.
5. **Otherwise unknown:** in a game, the room votes.

Each entry's keys are computed the way the validator's content load computes them. The word-list files are read with the content load's rules too: unknown fields, duplicate words, an id that doesn't match the file name, or a key that doesn't start with a round letter are all errors.

**Parity test:** answers generated from every word (as listed, with niqqud, without a vav or yod, with an extra vav, with the last letter replaced or dropped, with a letter inserted, against the wrong letter), plus edge cases, sent to both the running validator and the CLI:

```bash
make up && make bots-image && make native
bash native/rarebit-cli/tests/parity.sh       # last run: 9,053 answers, all identical
```

It runs inside the bots image (for its Node) on the stack's network. If one side's rules change, it lists the answers that differ and exits 1.

## Tests

`make native` runs the unit tests: UTF-8 (with Go's rune counting), the JSON reader and Go-compatible escaping, the word-list loading and every verdict, the commands and their exit codes, the docker command line, Windows argument quoting, and process exit codes and signals. They pass under AddressSanitizer and UndefinedBehaviorSanitizer too (`make native NATIVE_PRESET=linux-gcc-asan`).

Not verified yet: the Windows (MSVC) and macOS (Clang) builds, which come with the CI matrix.
