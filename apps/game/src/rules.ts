// The game's rules as pure functions: scoring, strikes, the end of the game, winners, the vote,
// and which (category, letter) a round uses. No I/O, so every rule is unit tested directly.

/** The 22 letters a round can use (final forms never start a word). */
export const LETTERS = "אבגדהוזחטיכלמנסעפצקרשת";

export const MAX_PLAYERS = 8;
export const MIN_PRIVATE_PLAYERS = 2;
export const POINTS_UNIQUE = 10;
export const POINTS_SHARED = 5;
export const MAX_RARITY_BONUS = 5;

export interface Player {
  id: string;
  nickname: string;
  score: number;
  strikes: number;
  eliminated: boolean;
  left: boolean;
  connected: boolean;
  joinedAt: number;
  /** The socket id of the player's current connection, so a late disconnect from an old one is ignored. */
  conn: string | null;
}

/** What evaluation said about one player's answer. */
export type Verdict = "valid" | "invalid" | "unknown" | "empty" | "blocked";

export interface Evaluated {
  playerId: string;
  answer: string;
  verdict: Verdict;
  /** The validator's comparison key: answers with the same key count as the same answer. */
  key: string;
  /** For "unknown" answers, the room vote's outcome. */
  accepted?: boolean;
}

export interface Scored extends Evaluated {
  final: "valid" | "invalid";
  points: number;
  strike: boolean;
}

export interface CategoryInfo {
  id: string;
  name: string;
  letters: string[];
}

export function isActive(p: Player): boolean {
  return !p.eliminated && !p.left;
}

/**
 * Valid and unique in the room: 10. Valid but shared (same key as another valid answer): 5. Plus a
 * rarity bonus of 0 to 5. Anything not valid scores nothing and is a strike. An unknown answer the
 * room accepted counts as valid.
 */
export function scoreRound(evaluated: Evaluated[], rarityBonus: (key: string) => number = () => 0): Scored[] {
  const finals = evaluated.map((e) => ({
    ...e,
    final: (e.verdict === "valid" || (e.verdict === "unknown" && e.accepted === true) ? "valid" : "invalid") as
      | "valid"
      | "invalid",
  }));
  const sameKey = new Map<string, number>();
  for (const e of finals) {
    if (e.final === "valid") sameKey.set(e.key, (sameKey.get(e.key) ?? 0) + 1);
  }
  return finals.map((e) => {
    if (e.final === "invalid") return { ...e, points: 0, strike: true };
    const base = sameKey.get(e.key) === 1 ? POINTS_UNIQUE : POINTS_SHARED;
    const bonus = Math.max(0, Math.min(MAX_RARITY_BONUS, Math.round(rarityBonus(e.key))));
    return { ...e, points: base + bonus, strike: false };
  });
}

/** Adds the round's points and strikes. 3 strikes eliminates a player, who keeps their points. */
export function applyScores(players: Player[], scored: Scored[], maxStrikes: number): Player[] {
  const byPlayer = new Map(scored.map((s) => [s.playerId, s]));
  return players.map((p) => {
    const s = byPlayer.get(p.id);
    if (!s || !isActive(p)) return p;
    const strikes = p.strikes + (s.strike ? 1 : 0);
    return { ...p, score: p.score + s.points, strikes, eliminated: strikes >= maxStrikes };
  });
}

/** The game ends after the last round, or when at most one player is still in it. */
export function isGameOver(players: Player[], round: number, maxRounds: number): boolean {
  return round >= maxRounds || players.filter(isActive).length <= 1;
}

/** The highest total wins, eliminated or not; then fewer strikes; still tied, they share the win. */
export function winners(players: Player[]): string[] {
  const ranked = [...players].sort((a, b) => b.score - a.score || a.strikes - b.strikes);
  const top = ranked[0];
  if (!top) return [];
  return ranked.filter((p) => p.score === top.score && p.strikes === top.strikes).map((p) => p.id);
}

/** Standings for display: score, then fewer strikes, then nickname. */
export function standings(players: Player[]): Player[] {
  return [...players].sort(
    (a, b) => b.score - a.score || a.strikes - b.strikes || a.nickname.localeCompare(b.nickname, "he"),
  );
}

/** A majority of the votes cast accepts; no votes, or a tie, rejects. */
export function voteAccepted(votes: boolean[]): boolean {
  const yes = votes.filter(Boolean).length;
  return yes > votes.length - yes;
}

/**
 * Picks the next round: a random category first (so large categories don't dominate), then a
 * random letter of it that this game hasn't used with that category. `used` holds "category:letter"
 * pairs. When every pair is used, any pair goes again.
 */
export function pickRound(
  categories: CategoryInfo[],
  used: ReadonlySet<string>,
  rng: () => number = Math.random,
): { category: CategoryInfo; letter: string } | null {
  const playable = categories.filter((c) => c.letters.length > 0);
  if (playable.length === 0) return null;
  const fresh = playable
    .map((c) => ({ c, letters: c.letters.filter((l) => !used.has(`${c.id}:${l}`)) }))
    .filter((x) => x.letters.length > 0);
  const pool = fresh.length > 0 ? fresh : playable.map((c) => ({ c, letters: c.letters }));
  const choice = pool[Math.floor(rng() * pool.length)]!;
  const letter = choice.letters[Math.floor(rng() * choice.letters.length)]!;
  return { category: choice.c, letter };
}

/**
 * A nickname: 2 to 16 Hebrew or Latin letters, digits, spaces, hyphens, underscores or
 * apostrophes. Only the scripts the offensive-word filter reads: a Cyrillic or Greek look-alike
 * letter would pass it unseen.
 */
export function cleanNickname(raw: string): string | null {
  const nick = raw.normalize("NFC").trim().replace(/\s+/g, " ");
  const length = [...nick].length;
  if (length < 2 || length > 16) return null;
  if (!/^[א-תA-Za-z0-9 _'-]+$/.test(nick)) return null;
  return nick;
}

export const MAX_ANSWER_CHARS = 64;

/** An answer as stored: trimmed, at most MAX_ANSWER_CHARS characters, empty when blank. */
export function cleanAnswer(raw: string): string {
  return [...raw.normalize("NFC").trim().replace(/\s+/g, " ")].slice(0, MAX_ANSWER_CHARS).join("");
}
