import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { config } from "./words.js";
import { seededRng } from "../src/rng.js";
import { percentiles } from "../src/stats.js";
import { scripted, strategyByName, type RoundContext } from "../src/strategy.js";
import { loadWords, wordsFor } from "../src/words.js";

const words = loadWords(config.wordsDir);

function context(rng = seededRng(1), over: Partial<RoundContext> = {}): RoundContext {
  return {
    round: 1,
    letter: "א",
    category: { id: "country", name: "ארץ" },
    deadline: 20_000,
    serverNow: 0,
    me: { playerId: "p1", index: 0 },
    words,
    rng,
    ...over,
  };
}

describe("the scripted strategy", () => {
  it("gives nicknames the game accepts", () => {
    const s = scripted();
    for (let i = 0; i < 8; i++) {
      const nick = s.nickname(i);
      expect(nick).toMatch(/^[א-תA-Za-z0-9 _'-]{2,16}$/);
    }
    expect(new Set(Array.from({ length: 8 }, (_, i) => s.nickname(i))).size).toBe(8);
  });

  it("answers mostly with listed words, sometimes made-up ones, sometimes nothing", async () => {
    const s = scripted();
    const rng = seededRng(42);
    const listed = new Set(wordsFor(words, "country", "א"));
    let valid = 0;
    let madeUp = 0;
    let none = 0;
    for (let i = 0; i < 1000; i++) {
      const a = await s.answer(context(rng));
      if (!a) none++;
      else if (listed.has(a.text)) valid++;
      else {
        madeUp++;
        expect(a.text.startsWith("א")).toBe(true);
      }
    }
    expect(valid / 1000).toBeGreaterThan(0.68);
    expect(valid / 1000).toBeLessThan(0.82);
    expect(madeUp / 1000).toBeGreaterThan(0.1);
    expect(none / 1000).toBeGreaterThan(0.05);
  });

  it("answers between 20% and 70% of the way through the round", async () => {
    const s = scripted({ valid: 1, invalid: 0, accept: 0.5 });
    const rng = seededRng(7);
    for (let i = 0; i < 200; i++) {
      const a = await s.answer(context(rng, { serverNow: 5_000, deadline: 25_000 }));
      expect(a!.afterMs).toBeGreaterThanOrEqual(4_000);
      expect(a!.afterMs).toBeLessThanOrEqual(14_000);
    }
  });

  it("makes up a word when the list has nothing for the letter", async () => {
    const s = scripted({ valid: 1, invalid: 0, accept: 0.5 });
    const a = await s.answer(context(seededRng(3), { category: { id: "no-such-category", name: "?" } }));
    expect(a).not.toBeNull();
    expect(a!.text.startsWith("א")).toBe(true);
  });

  it("accepts about half of the votes, and repeats with the same seed", async () => {
    const s = scripted();
    const votes = async (seed: number) => {
      const rng = seededRng(seed);
      const out: Array<boolean | null> = [];
      for (let i = 0; i < 400; i++) out.push(await s.vote({ round: 1, item: { playerId: "p2", nickname: "x", answer: "y" }, me: { playerId: "p1", index: 0 }, rng }));
      return out;
    };
    const a = await votes(9);
    expect(a.filter(Boolean).length / 400).toBeGreaterThan(0.4);
    expect(a.filter(Boolean).length / 400).toBeLessThan(0.6);
    expect(await votes(9)).toEqual(a);
  });

  it("is found by name, and an unknown name is an error", () => {
    expect(strategyByName("scripted").name).toBe("scripted");
    expect(() => strategyByName("rare-hunter")).toThrow("unknown strategy");
  });
});

describe("the word lists", () => {
  it("are read from data/categories, keyed by first letter", () => {
    expect(words.size).toBeGreaterThanOrEqual(6);
    for (const [, byLetter] of words) {
      for (const [letter, list] of byLetter) for (const w of list) expect([...w][0]).toBe(letter);
    }
    expect(wordsFor(words, "country", "א")).toContain("אוסטריה");
  });

  it("fail on a directory with no category files", () => {
    expect(() => loadWords(fileURLToPath(new URL(".", import.meta.url)))).toThrow("no category files");
  });
});

describe("percentiles", () => {
  it.each([
    { values: [], want: { n: 0, p50: 0, p95: 0, p99: 0, max: 0 } },
    { values: [5], want: { n: 1, p50: 5, p95: 5, p99: 5, max: 5 } },
    { values: Array.from({ length: 100 }, (_, i) => i + 1), want: { n: 100, p50: 50, p95: 95, p99: 99, max: 100 } },
    { values: [3, 1, 2], want: { n: 3, p50: 2, p95: 3, p99: 3, max: 3 } },
  ])("of $values.length values", ({ values, want }) => {
    expect(percentiles(values)).toEqual(want);
  });
});
