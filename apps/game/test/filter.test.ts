import { describe, expect, it } from "vitest";
import { isBlocked } from "../src/filter/filter.js";
import { filterCompact, filterTokens } from "../src/filter/normalize.js";

describe("filter normalization", () => {
  it("drops niqqud, final letters, case, punctuation and digit look-alikes", () => {
    expect(filterTokens("שָׁלוֹם, עולם!")).toEqual(["שלומ", "עולמ"]);
    expect(filterCompact("F.U.C.K")).toBe("fuck");
    expect(filterCompact("b1tch")).toBe("bitch");
  });
});

describe("isBlocked", () => {
  it.each([
    // Distinctive terms anywhere, however they're spaced or decorated
    { text: "fuck", field: "nickname", blocked: true },
    { text: "fuckface", field: "nickname", blocked: true },
    { text: "F u c k", field: "nickname", blocked: true },
    { text: "שַׁרְמוּטָה", field: "answer", blocked: true },
    { text: "כוס אמק", field: "answer", blocked: true },
    { text: "כוסאמק", field: "nickname", blocked: true },
    // Whole words only: they hide inside innocent ones
    { text: "shit", field: "answer", blocked: true },
    { text: "shitake", field: "answer", blocked: false },
    { text: "rape", field: "nickname", blocked: true },
    { text: "grape", field: "nickname", blocked: false },
    { text: "grapefruit", field: "answer", blocked: false },
    { text: "זונה", field: "answer", blocked: true },
    { text: "חזונה", field: "answer", blocked: false },
    // Nicknames only: real words that could be answers somewhere
    { text: "כוס", field: "nickname", blocked: true },
    { text: "כוס", field: "answer", blocked: false },
    { text: "היטלר", field: "answer", blocked: false },
    { text: "היטלר 88", field: "nickname", blocked: true },
    // Ordinary text
    { text: "ישראל", field: "answer", blocked: false },
    { text: "דני", field: "nickname", blocked: false },
    { text: "Scunthorpe", field: "nickname", blocked: true }, // the known cost of matching inside words
    { text: "", field: "answer", blocked: false },
  ] as const)("$field \"$text\" → $blocked", ({ text, field, blocked }) => {
    expect(isBlocked(text, field)).toBe(blocked);
  });
});
