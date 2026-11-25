// The parts of the game's client protocol the UI uses (apps/game/README.md → Protocol, ADR 0020).
// The room snapshot carries everything a screen needs; the UI renders from it alone.
export type Phase = "lobby" | "countdown" | "round" | "voting" | "results" | "ended";

export interface Reply {
  ok: boolean;
  error?: string;
  [key: string]: unknown;
}

export interface PublicPlayer {
  id: string;
  nickname: string;
  score: number;
  strikes: number;
  eliminated: boolean;
  left: boolean;
  connected: boolean;
}

export type Verdict = "valid" | "invalid" | "unknown" | "empty" | "blocked";

export interface ResultLine {
  playerId: string;
  nickname: string;
  answer: string;
  verdict: Verdict;
  final: "valid" | "invalid";
  points: number;
  strike: boolean;
}

export interface RoundResults {
  round: number;
  letter: string;
  category: { id: string; name: string };
  answers: ResultLine[];
}

export interface RoomSnapshot {
  code: string;
  type: "private" | "public";
  phase: Phase;
  hostId: string | null;
  players: PublicPlayer[];
  round: number;
  maxRounds: number;
  letter: string | null;
  category: { id: string; name: string } | null;
  deadline: number | null;
  serverNow: number;
  voting: Array<{ playerId: string; nickname: string; answer: string }> | null;
  lastResults: RoundResults | null;
  winners: string[] | null;
  notice: string | null;
}

/** A room code: 6 characters, no 0/O/1/I/L. */
export const ROOM_CODE = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$/;
export const MAX_PLAYERS = 8;
export const MIN_PRIVATE_PLAYERS = 2;
