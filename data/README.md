# data

Game content as files in git: the categories and their word lists. Content changes only by pull request. [`validator migrate`](../apps/validator/README.md#validator-migrate) loads these files into Postgres, and it's the only writer of content into the database.

## Layout

One file per category in `categories/`, named by its id:

```json
{
  "id": "animal",
  "name": "חי",
  "kind": "regular",
  "lists": [
    { "source": "Rarebit contributors", "license": "MIT", "words": ["אריה", "..."] }
  ]
}
```

- `kind` is `regular` (ארץ, עיר, חי, צומח, שם, מקצוע) or `creative`.
- **Each list carries its own `source` and `license`**, so every word's provenance is clear.
  - A list from open data adds `url`, `query` (how it was produced) and `retrieved` (a date).
  - Allowed licenses: `CC0-1.0` and `MIT`. Adding another is a decision for review.
- Words are stored clean:
  - Hebrew letters, single spaces, hyphens, and geresh/gershayim (`' " ׳ ״`);
  - no niqqud;
  - 2–30 letters.
- Each list is sorted, and a word appears once per category, across all its lists.

### Which spellings to list

[hebrew-normalize](../native/hebrew-normalize/README.md) matches answers, so some variants never need listing:
- niqqud, final letters, spaces and punctuation;
- full vs defective spelling that only adds or drops vav and yod (שולחן / שלחן, שווייץ / שוויץ);
- a one-letter typo in words of 4+ letters.

Spellings that differ in other letters do need their own entry, e.g. שבדיה / שוודיה (ב vs וו).

**Names and titles** (people, brands, companies, movies, series) are listed as players write them. The round's letter is the first letter of the answer, so:
- list the full name, and also the surname alone when that's how people say it (דוד בן גוריון, בן גוריון);
- list a foreign title by its Hebrew title in Israel (מלך האריות), or by the original name when that's what people say (פרוזן).

Different words can share a spelling key, e.g. שירה / שרה, תומר / תמר, אורז / ארז. Keep both. The validator checks exact matches first, and within one category both are valid answers anyway.

## Sources

| Source | License | How it gets here |
|---|---|---|
| Rarebit contributors | MIT (this repository) | Written by hand: common everyday words and spellings |

Open data (Wikidata, CC0) is planned as a second source, through a script that adds a separate list per category.

## Change the content

1. Edit the right list.
2. Run `python data/tools/check_data.py --fix`, which sorts the lists and drops duplicates (the first list wins), then `make check`. The `word-lists` hook runs the same check.
3. Open a PR. The word counts per starting letter are worth a look in review:

```bash
python data/tools/check_data.py --coverage
```

The validator's `GET /v1/categories` leaves out a letter that has fewer than 3 words in a category, so rounds never use it. Some gaps are real: few country names start with ז, ח, כ or ע.
