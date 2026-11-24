# 0012. Keep word lists as one JSON file per category, each list with its own source and license

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

Answers are validated against word lists per category. The lists:
- come from more than one source (open data plus hand-written words), and each source has a license that must stay attached to its words;
- change only through pull requests, from humans and later from content agents, so diffs must be reviewable line by line;
- are loaded into Postgres by a Go job (`migrate`, later a loader Job);
- are checked by `make check`.

## Decision

- One file per category, `data/categories/<id>.json`, with:
  - `id`, a Hebrew `name` and a `kind`;
  - a list of word lists, each with its `source`, an SPDX `license`, optional `url`, `query` and `retrieved` fields, and its `words`.
- Words are stored clean (Hebrew letters, spaces, hyphens, geresh/gershayim; no niqqud), sorted, one per line in the JSON array, and unique within a category.
- `data/tools/check_data.py` enforces the format and the license allowlist (`CC0-1.0`, `MIT`). It runs as the `word-lists` pre-commit hook, and `--coverage` reports words per starting letter.
- The first lists are written by contributors (MIT). An open-data source (Wikidata, CC0) is added later as its own list in each file, by a committed script that regenerates that list and drops its words from the other lists.

## Alternatives considered

| Option | Why not |
|---|---|
| YAML | Comments are nice, but Go would need a YAML library; JSON is in Go's and Python's standard libraries and is just as diffable with one word per line |
| One CSV or text file per category | Mixing sources in one file loses which license applies to which word |
| One file per source per category | Twice the files, and duplicates across files are harder to see |
| Word lists only in the database | No review, no history, no way for agents to propose changes by PR |

## Consequences

- **Good:**
  - provenance and license per word;
  - small, reviewable diffs;
  - parsing with only the standard library;
  - a checker that blocks malformed or unlicensed content before it merges.
- **Bad / risks:**
  - large categories make large files (thousands of lines);
  - JSON allows no comments, so notes go in the PR or in `data/README.md`.
- **Follow-ups:**
  - the loader Job, and data CI with a preview;
  - creative categories (מנהיג, מותג, סרט);
  - per-letter coverage targets once games are played.

## How we'll know it was right

Content PRs from humans and agents stay small and reviewable, and the loader never meets a file it can't parse.
