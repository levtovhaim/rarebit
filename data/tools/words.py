"""Shared rules for words in data/categories/*.json (used by check_data.py and wikidata_seed.py)."""

from __future__ import annotations

import re

# The 22 letters a round can use. Final forms (ך ם ן ף ץ) never start a word.
LETTERS = "אבגדהוזחטיכלמנסעפצקרשת"

# Licenses a word list may carry. Adding one is a decision for review, not a typo fix.
LICENSES = {"CC0-1.0", "MIT"}

NIQQUD = re.compile("[\u0591-\u05bd\u05bf-\u05c7]")  # points and cantillation; U+05BE maqaf is kept
QUALIFIER = re.compile(r"\s*[(\[].*?[)\]]\s*")
ALLOWED = re.compile("^[\u05d0-\u05ea][\u05d0-\u05ea \\-'\"\u05f3\u05f4]*$")
MAX_LETTERS = 30


def letters_in(word: str) -> int:
    return sum(1 for c in word if "\u05d0" <= c <= "\u05ea")


def clean(label: str) -> str | None:
    """The form a word is stored in, or None if it can't be an answer.

    Hebrew letters, single spaces, hyphens, and geresh/gershayim (as ' " ׳ ״) only; niqqud and
    parenthesized qualifiers removed; maqaf written as a hyphen; 2 to 30 letters.
    """
    word = QUALIFIER.sub(" ", label)
    word = NIQQUD.sub("", word).replace("\u05be", "-")
    word = " ".join(word.split()).strip(" -")
    if not ALLOWED.match(word):
        return None
    if not 2 <= letters_in(word) <= MAX_LETTERS:
        return None
    return word
