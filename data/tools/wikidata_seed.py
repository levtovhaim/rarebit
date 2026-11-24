#!/usr/bin/env python3
"""Refresh the Wikidata word list in each data/categories/<id>.json file.

Run from the repository root, with the Python from .mise.toml (standard library only):

    python data/tools/wikidata_seed.py            # every category
    python data/tools/wikidata_seed.py country    # one category

It runs one SPARQL query per category against the Wikidata Query Service, keeps the Hebrew labels
that are usable as answers (Hebrew letters, spaces, hyphens, geresh/gershayim only; niqqud and
parenthesized qualifiers removed), and replaces only the list whose source is "Wikidata". Lists
from other sources in the same file are left as they are, minus any word Wikidata now provides.
Wikidata content is CC0-1.0. Set WIKIDATA_USER_AGENT to identify your client to the service.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from words import clean

ROOT = Path(__file__).resolve().parents[2]
CATEGORIES = ROOT / "data" / "categories"
ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = os.environ.get("WIKIDATA_USER_AGENT", "seed-word-lists/0.1 (python-urllib)")

# Hebrew label of an item, in the variable ?label.
HE_LABEL = '?item rdfs:label ?label . FILTER(LANG(?label) = "he")'

QUERIES = {
    # Sovereign states and countries that still exist.
    "country": f"""
SELECT DISTINCT ?label WHERE {{
  {{ ?item wdt:P31 wd:Q3624078 }} UNION {{ ?item wdt:P31 wd:Q6256 }}
  FILTER NOT EXISTS {{ ?item wdt:P576 ?dissolved }}
  {HE_LABEL}
}}""",
    # Cities of 100,000+ people anywhere, plus every settlement in Israel.
    "city": f"""
SELECT DISTINCT ?label WHERE {{
  {{ ?item wdt:P31/wdt:P279? wd:Q515 ; wdt:P1082 ?population . FILTER(?population >= 100000) }}
  UNION
  {{ ?item wdt:P17 wd:Q801 ; wdt:P31/wdt:P279* wd:Q486972 . }}
  {HE_LABEL}
}}""",
    # Animal taxa (descendants of Animalia) with a Hebrew common name or a Hebrew Wikipedia article.
    "animal": """
SELECT DISTINCT ?label WHERE {
  { ?item p:P1843/ps:P1843 ?label . FILTER(LANG(?label) = "he") }
  UNION
  { ?article schema:about ?item ; schema:isPartOf <https://he.wikipedia.org/> .
    ?item wdt:P31 wd:Q16521 ; rdfs:label ?label . FILTER(LANG(?label) = "he") }
  ?item wdt:P171+ wd:Q729 .
}""",
    # Plant taxa (descendants of Plantae), the same way.
    "plant": """
SELECT DISTINCT ?label WHERE {
  { ?item p:P1843/ps:P1843 ?label . FILTER(LANG(?label) = "he") }
  UNION
  { ?article schema:about ?item ; schema:isPartOf <https://he.wikipedia.org/> .
    ?item wdt:P31 wd:Q16521 ; rdfs:label ?label . FILTER(LANG(?label) = "he") }
  ?item wdt:P171+ wd:Q756 .
}""",
    # Given names: male, female and unisex.
    "name": f"""
SELECT DISTINCT ?label WHERE {{
  VALUES ?type {{ wd:Q202444 wd:Q12308941 wd:Q11879590 wd:Q3409032 }}
  ?item wdt:P31 ?type .
  {HE_LABEL}
}}""",
    # Professions and occupations.
    "occupation": f"""
SELECT DISTINCT ?label WHERE {{
  VALUES ?type {{ wd:Q28640 wd:Q12737077 }}
  ?item wdt:P31 ?type .
  {HE_LABEL}
}}""",
}

META = {
    "country": ("ארץ", "regular"),
    "city": ("עיר", "regular"),
    "animal": ("חי", "regular"),
    "plant": ("צומח", "regular"),
    "name": ("שם", "regular"),
    "occupation": ("מקצוע", "regular"),
}

def fetch(query: str, attempts: int = 5) -> list[str]:
    """Run a query, backing off on 429/503 as the service asks (Retry-After), or 65 s."""
    url = ENDPOINT + "?" + urllib.parse.urlencode({"query": query, "format": "json"})
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": "application/sparql-results+json"}
    )
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = json.load(response)
            return [row["label"]["value"] for row in data["results"]["bindings"]]
        except urllib.error.HTTPError as error:
            if error.code not in (429, 503) or attempt == attempts:
                raise
            retry_after = error.headers.get("Retry-After", "")
            wait = int(retry_after) if retry_after.isdigit() else 65
            print(f"  HTTP {error.code}, waiting {wait}s (attempt {attempt}/{attempts})", flush=True)
            time.sleep(wait)
    raise RuntimeError("unreachable")


def load(category: str) -> dict:
    path = CATEGORIES / f"{category}.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    name, kind = META[category]
    return {"id": category, "name": name, "kind": kind, "lists": []}


def save(category: str, doc: dict) -> None:
    CATEGORIES.mkdir(parents=True, exist_ok=True)
    text = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
    (CATEGORIES / f"{category}.json").write_text(text, encoding="utf-8", newline="\n")


def refresh(category: str) -> None:
    words = sorted({w for w in (clean(label) for label in fetch(QUERIES[category])) if w})
    doc = load(category)
    other = [lst for lst in doc["lists"] if lst["source"] != "Wikidata"]
    taken = set(words)
    for lst in other:
        lst["words"] = [w for w in lst["words"] if w not in taken]
    wikidata = {
        "source": "Wikidata",
        "license": "CC0-1.0",
        "url": "https://www.wikidata.org/",
        "query": f"data/tools/wikidata_seed.py ({category})",
        "retrieved": dt.date.today().isoformat(),
        "words": words,
    }
    doc["lists"] = [wikidata, *other]
    save(category, doc)
    print(f"{category}: {len(words)} words from Wikidata")


def main(argv: list[str]) -> None:
    categories = argv or list(QUERIES)
    for category in categories:
        if category not in QUERIES:
            sys.exit(f"unknown category: {category} (known: {', '.join(QUERIES)})")
    for i, category in enumerate(categories):
        if i > 0:
            time.sleep(61)  # at most one query a minute: the service's limit when it's under load
        refresh(category)


if __name__ == "__main__":
    main(sys.argv[1:])
