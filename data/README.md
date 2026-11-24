# data

Game content as files in git: the categories and their word lists. Content changes only by pull request. The validator's `migrate` job loads these files into Postgres; later a loader Job does that on every merge.

## Layout

One file per category in `categories/`, named by its id:

```json
{
  "id": "animal",
  "name": "חי",
  "kind": "regular",
  "lists": [
    {
      "source": "Wikidata",
      "license": "CC0-1.0",
      "url": "https://www.wikidata.org/",
      "query": "data/tools/wikidata_seed.py (animal)",
      "retrieved": "2026-11-24",
      "words": ["אריה", "..."]
    },
    { "source": "Rarebit contributors", "license": "MIT", "words": ["..."] }
  ]
}
```

- `kind` is `regular` (ארץ, עיר, חי, צומח, שם, מקצוע) or `creative`.
- **Each list carries its own source and license**, so every word's provenance is clear. Allowed licenses: `CC0-1.0` and `MIT`. Adding another is a decision for review.
- Words are stored clean:
  - Hebrew letters, single spaces, hyphens, and geresh/gershayim (`' " ׳ ״`);
  - no niqqud;
  - 2–30 letters.
  Variants such as niqqud, final letters, and full vs defective spelling are handled at match time by [hebrew-normalize](../native/hebrew-normalize/README.md), so they don't need to be listed.
- Each list is sorted, and a word appears once per category, across all its lists.

## Sources

| Source | License | How it gets here |
|---|---|---|
| [Wikidata](https://www.wikidata.org/) | CC0-1.0 | `python data/tools/wikidata_seed.py [category]` runs one SPARQL query per category, keeps the usable Hebrew labels, and replaces that file's Wikidata list. It queries at most once a minute and backs off when the service asks. Set `WIKIDATA_USER_AGENT` to identify your client. |
| Rarebit contributors | MIT (this repository) | Written by hand, mostly common words and spellings that Wikidata labels miss |

**Today the seed is the contributors' lists only.** The first Wikidata fetch (2026-11-24) was refused: the query service was rate-limiting every client during an outage (HTTP 429). Run the script once the service answers again; it adds a Wikidata list to each file and removes the words it now provides from the contributors' list.

## Change the content

1. Edit the right list, or run the Wikidata script.
2. Run `python data/tools/check_data.py --fix`, which sorts the lists and drops duplicates (the first list wins), then `make check`. The `word-lists` hook runs the same check.
3. Open a PR. The word counts per starting letter are worth a look in review:

```bash
python data/tools/check_data.py --coverage
```

A letter with fewer than 3 words in a category is skipped by the game for that category. Some gaps are real: few country names start with ז, ח, כ or ע.
