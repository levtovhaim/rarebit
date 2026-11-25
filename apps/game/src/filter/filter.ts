// The offensive-word filter for nicknames and answers. A blocked nickname is refused at join; a
// blocked answer is scored as invalid (a strike), like any other answer that isn't a word.
import { BLOCKED_ANYWHERE, BLOCKED_NICKNAME_WORDS, BLOCKED_WORDS } from "./blocklist.js";
import { filterCompact, filterTokens } from "./normalize.js";

export type FilterField = "nickname" | "answer";

const anywhere = BLOCKED_ANYWHERE.map(filterCompact);
const words = new Set(BLOCKED_WORDS.map(filterCompact));
const nicknameWords = new Set(BLOCKED_NICKNAME_WORDS.map(filterCompact));

export function isBlocked(text: string, field: FilterField): boolean {
  const tokens = filterTokens(text);
  const compact = tokens.join("");
  if (compact === "") return false;
  if (anywhere.some((term) => compact.includes(term))) return true;
  const wholeWords = field === "nickname" ? [words, nicknameWords] : [words];
  return wholeWords.some((set) => set.has(compact) || tokens.some((t) => set.has(t)));
}
