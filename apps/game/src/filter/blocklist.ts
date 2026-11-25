// Words the game refuses as nicknames or answers: profanity and slurs, in Hebrew and English.
// Deliberately short: the filter blocks, it doesn't report, so a false positive costs a player
// their nickname or a point. Changes go through a PR like any other content.
//
// Each term is written as it's spelled; filter.ts reduces it to the same form as the text it
// checks (no niqqud or final letters, lowercase).

/** Blocked when they appear anywhere, even inside a longer word: distinctive enough to be safe. */
export const BLOCKED_ANYWHERE = [
  "שרמוטה",
  "שרמוט",
  "מזדיין",
  "מזדיינת",
  "כוס אמק",
  "כוס עמק",
  "כוס אחתק",
  "בן זונה",
  "מניאק",
  "ערבוש",
  "fuck",
  "cunt",
  "nigger",
  "nigga",
  "faggot",
  "bitch",
  "asshole",
  "whore",
];

/** Blocked as a whole word, or as the whole text run together: these appear inside innocent words. */
export const BLOCKED_WORDS = [
  "זונה",
  "זונות",
  "חרא",
  "כושי",
  "כושית",
  "כוסית",
  "shit",
  "dick",
  "cock",
  "pussy",
  "fag",
  "slut",
  "retard",
  "rape",
  "kkk",
];

/**
 * Nicknames only: everyday words or names that could be a real answer in some category (כוס is
 * also "cup", זין also "weapon"), but not a name to play under.
 */
export const BLOCKED_NICKNAME_WORDS = ["זין", "זיין", "כוס", "היטלר", "נאצי", "hitler", "nazi"];
