import { describe, expect, it } from "vitest";
import {
  applyScores,
  cleanAnswer,
  cleanNickname,
  isGameOver,
  pickRound,
  scoreRound,
  voteAccepted,
  winners,
  type Evaluated,
  type Player,
} from "../src/rules.js";

const player = (id: string, over: Partial<Player> = {}): Player => ({
  id,
  nickname: id,
  score: 0,
  strikes: 0,
  eliminated: false,
  left: false,
  connected: true,
  joinedAt: 0,
  conn: null,
  ...over,
});
const answer = (playerId: string, verdict: Evaluated["verdict"], key: string, accepted?: boolean): Evaluated => ({
  playerId,
  answer: key,
  verdict,
  key,
  ...(accepted === undefined ? {} : { accepted }),
});

describe("scoreRound", () => {
  it.each([
    { name: "unique valid", answers: [answer("a", "valid", "ישראל")], points: { a: 10 }, strikes: { a: false } },
    {
      name: "shared valid",
      answers: [answer("a", "valid", "ישראל"), answer("b", "valid", "ישראל"), answer("c", "valid", "צרפת")],
      points: { a: 5, b: 5, c: 10 },
      strikes: { a: false, b: false, c: false },
    },
    {
      name: "invalid, empty and blocked are strikes",
      answers: [answer("a", "invalid", "x"), answer("b", "empty", ""), answer("c", "blocked", "")],
      points: { a: 0, b: 0, c: 0 },
      strikes: { a: true, b: true, c: true },
    },
    {
      name: "unknown: accepted by the vote is valid, rejected is a strike",
      answers: [answer("a", "unknown", "אטלנטיס", true), answer("b", "unknown", "גונדור", false)],
      points: { a: 10, b: 0 },
      strikes: { a: false, b: true },
    },
    {
      name: "an accepted unknown shares with a valid answer of the same key",
      answers: [answer("a", "unknown", "ישראל", true), answer("b", "valid", "ישראל")],
      points: { a: 5, b: 5 },
      strikes: { a: false, b: false },
    },
  ])("$name", ({ answers, points, strikes }) => {
    const scored = scoreRound(answers);
    expect(Object.fromEntries(scored.map((s) => [s.playerId, s.points]))).toEqual(points);
    expect(Object.fromEntries(scored.map((s) => [s.playerId, s.strike]))).toEqual(strikes);
  });

  it("adds a rarity bonus, clamped to 0..5", () => {
    const bonus = (key: string) => (key === "rare" ? 9 : -3);
    const scored = scoreRound([answer("a", "valid", "rare"), answer("b", "valid", "common")], bonus);
    expect(scored.map((s) => s.points)).toEqual([15, 10]);
  });
});

describe("applyScores", () => {
  it("adds points, counts strikes, eliminates at the limit and keeps the points", () => {
    const players = [player("a", { score: 20, strikes: 2 }), player("b")];
    const scored = scoreRound([answer("a", "invalid", "x"), answer("b", "valid", "y")]);
    const [a, b] = applyScores(players, scored, 3);
    expect(a).toMatchObject({ score: 20, strikes: 3, eliminated: true });
    expect(b).toMatchObject({ score: 10, strikes: 0, eliminated: false });
  });

  it("leaves eliminated and departed players alone", () => {
    const players = [player("a", { eliminated: true, strikes: 3 }), player("b", { left: true })];
    const scored = scoreRound([answer("a", "valid", "x"), answer("b", "valid", "y")]);
    expect(applyScores(players, scored, 3)).toEqual(players);
  });
});

describe("isGameOver", () => {
  it.each([
    { name: "rounds left, two active", round: 3, eliminated: [false, false], over: false },
    { name: "last round played", round: 10, eliminated: [false, false], over: true },
    { name: "only one player active", round: 3, eliminated: [false, true], over: true },
  ])("$name", ({ round, eliminated, over }) => {
    const players = eliminated.map((e, i) => player(String(i), { eliminated: e }));
    expect(isGameOver(players, round, 10)).toBe(over);
  });
});

describe("winners", () => {
  it.each([
    { name: "highest score", players: [player("a", { score: 30 }), player("b", { score: 20 })], want: ["a"] },
    {
      name: "an eliminated player can still win",
      players: [player("a", { score: 40, eliminated: true, strikes: 3 }), player("b", { score: 20 })],
      want: ["a"],
    },
    {
      name: "a tie goes to fewer strikes",
      players: [player("a", { score: 30, strikes: 2 }), player("b", { score: 30, strikes: 1 })],
      want: ["b"],
    },
    {
      name: "still tied: a shared win",
      players: [player("a", { score: 30, strikes: 1 }), player("b", { score: 30, strikes: 1 }), player("c", { score: 5 })],
      want: ["a", "b"],
    },
  ])("$name", ({ players, want }) => {
    expect(winners(players).sort()).toEqual(want);
  });
});

describe("voteAccepted", () => {
  it.each([
    { votes: [true], want: true },
    { votes: [true, true, false], want: true },
    { votes: [true, false], want: false },
    { votes: [false], want: false },
    { votes: [], want: false },
  ])("$votes → $want", ({ votes, want }) => {
    expect(voteAccepted(votes)).toBe(want);
  });
});

describe("pickRound", () => {
  const categories = [
    { id: "country", name: "ארץ", letters: ["א", "ב"] },
    { id: "city", name: "עיר", letters: ["ג"] },
    { id: "empty", name: "ריק", letters: [] },
  ];

  it("never picks a category with no playable letters, and avoids used pairs", () => {
    const used = new Set(["country:א", "city:ג"]);
    for (let i = 0; i < 50; i++) {
      const pick = pickRound(categories, used, () => (i % 10) / 10);
      expect(pick).toEqual({ category: categories[0], letter: "ב" });
    }
  });

  it("starts over when every pair has been played", () => {
    const used = new Set(["country:א", "country:ב", "city:ג"]);
    expect(pickRound(categories, used, () => 0)).not.toBeNull();
  });

  it("returns null with nothing playable", () => {
    expect(pickRound([{ id: "x", name: "x", letters: [] }], new Set())).toBeNull();
  });
});

describe("cleanNickname and cleanAnswer", () => {
  it.each([
    { raw: "  דני  ", want: "דני" },
    { raw: "Player 1", want: "Player 1" },
    { raw: "a", want: null },
    { raw: "x".repeat(17), want: null },
    { raw: "<script>", want: null },
    { raw: "דני   כהן", want: "דני כהן" },
  ])("nickname $raw → $want", ({ raw, want }) => {
    expect(cleanNickname(raw)).toBe(want);
  });

  it("trims answers and caps them at 64 characters", () => {
    expect(cleanAnswer("  ישראל  ")).toBe("ישראל");
    expect([...cleanAnswer("א".repeat(100))].length).toBe(64);
    expect(cleanAnswer("   ")).toBe("");
  });
});
