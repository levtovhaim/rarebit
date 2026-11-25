// The forms the offensive-word filter compares. Coarser than native/hebrew-normalize on purpose:
// it only has to see through niqqud, final letters, spacing, punctuation, case and digit swaps.

const NIQQUD = /[֑-ֽֿ-ׇ]/g; // points and cantillation
const FINALS: Record<string, string> = { "ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ" };
const LOOKALIKES: Record<string, string> = { "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s" };

/** The words of a text, each reduced to Hebrew letters (no finals) and lowercase a-z. */
export function filterTokens(text: string): string[] {
  const s = text
    .normalize("NFKD")
    .replace(NIQQUD, "")
    .replace(/\p{M}/gu, "") // Latin accents, after NFKD
    .toLowerCase()
    .replace(/[ךםןףץ]/g, (c) => FINALS[c] ?? c)
    .replace(/[013457@$]/g, (c) => LOOKALIKES[c] ?? c);
  return s.split(/[^a-zא-ת]+/).filter(Boolean);
}

/** All the words run together: catches spaced-out or punctuated spellings. */
export function filterCompact(text: string): string {
  return filterTokens(text).join("");
}
