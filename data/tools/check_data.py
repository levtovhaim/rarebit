#!/usr/bin/env python3
"""Check the word lists in data/categories/*.json (run by `make check`).

    python data/tools/check_data.py              # check; exit 1 on any problem
    python data/tools/check_data.py --fix        # also sort lists and drop duplicates, then check
    python data/tools/check_data.py --coverage   # also print words per starting letter

A category file holds an id (its file name), a Hebrew name, a kind (regular or creative) and one
or more lists. Each list names its source and license and holds words that are already clean
(see words.py), sorted, and unique within the whole category. Words from the first list win
when --fix drops duplicates, so put the authoritative source first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from words import LETTERS, LICENSES, clean

ROOT = Path(__file__).resolve().parents[2]
CATEGORIES = ROOT / "data" / "categories"
KINDS = {"regular", "creative"}
TOP_KEYS = {"id", "name", "kind", "lists"}
LIST_KEYS = {"source", "license", "words"}
OPTIONAL_LIST_KEYS = {"url", "query", "retrieved"}
THIN = 3  # fewer words than this for a letter: the game skips that letter for the category


def fix(doc: dict) -> None:
    seen: set[str] = set()
    for lst in doc.get("lists", []):
        words = []
        for word in sorted(set(lst.get("words", []))):
            if word not in seen:
                seen.add(word)
                words.append(word)
        lst["words"] = words


def check(path: Path, doc: dict) -> list[str]:
    errors = []
    where = path.relative_to(ROOT).as_posix()
    if set(doc) != TOP_KEYS:
        errors.append(f"{where}: keys must be {sorted(TOP_KEYS)}, got {sorted(doc)}")
        return errors
    if doc["id"] != path.stem:
        errors.append(f"{where}: id {doc['id']!r} must match the file name")
    if doc["kind"] not in KINDS:
        errors.append(f"{where}: kind must be one of {sorted(KINDS)}")
    if clean(doc["name"]) != doc["name"]:
        errors.append(f"{where}: name {doc['name']!r} isn't a clean Hebrew word")
    if not doc["lists"]:
        errors.append(f"{where}: no lists")
    seen: dict[str, str] = {}
    for i, lst in enumerate(doc["lists"]):
        label = f"{where} list {i} ({lst.get('source', '?')})"
        missing = LIST_KEYS - set(lst)
        extra = set(lst) - LIST_KEYS - OPTIONAL_LIST_KEYS
        if missing or extra:
            errors.append(f"{label}: missing {sorted(missing)}, unknown {sorted(extra)}")
            continue
        if lst["license"] not in LICENSES:
            errors.append(f"{label}: license {lst['license']!r} isn't one of {sorted(LICENSES)}")
        words = lst["words"]
        if not words:
            errors.append(f"{label}: empty")
        if words != sorted(words):
            errors.append(f"{label}: not sorted (run with --fix)")
        for word in words:
            if clean(word) != word:
                errors.append(f"{label}: {word!r} isn't clean (allowed: Hebrew letters, space, - ' \" ׳ ״)")
            if word in seen:
                errors.append(f"{label}: {word!r} is already in {seen[word]} (run with --fix)")
            seen[word] = lst["source"]
    return errors


def coverage(docs: dict[str, dict]) -> None:
    print("words per starting letter (" + f"< {THIN}: the game skips the letter)")
    print("category    total  " + " ".join(LETTERS))
    for category, doc in docs.items():
        words = [w for lst in doc["lists"] for w in lst["words"]]
        counts = [sum(1 for w in words if w[0] == letter) for letter in LETTERS]
        thin = [letter for letter, n in zip(LETTERS, counts) if n < THIN]
        cells = " ".join(f"{min(n, 999):>3}" for n in counts)
        print(f"{category:<11} {len(words):>5}  {cells}")
        if thin:
            print(f"{'':<11}  thin: {' '.join(thin)}")


def main(argv: list[str]) -> int:
    paths = sorted(CATEGORIES.glob("*.json"))
    if not paths:
        print("no category files in data/categories/", file=sys.stderr)
        return 1
    docs: dict[str, dict] = {}
    errors: list[str] = []
    for path in paths:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            errors.append(f"{path.relative_to(ROOT).as_posix()}: invalid JSON: {error}")
            continue
        if "--fix" in argv:
            fix(doc)
            path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
        errors += check(path, doc)
        docs[path.stem] = doc
    for error in errors:
        print(error, file=sys.stderr)
    if "--coverage" in argv:
        coverage(docs)
    if errors:
        print(f"{len(errors)} problem(s) in data/categories/", file=sys.stderr)
        return 1
    total = sum(len(lst["words"]) for doc in docs.values() for lst in doc["lists"])
    print(f"data/categories: {len(docs)} categories, {total} words, all valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
