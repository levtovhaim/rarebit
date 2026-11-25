// The parts of the game's client protocol the bots use (apps/game/README.md → Protocol, ADR 0020).
// Kept by hand: the integration tests run the bots against the real game server, so a drift
// shows up there.
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

export interface ResultLine {
  playerId: string;
  nickname: string;
  answer: string;
  verdict: "valid" | "invalid" | "unknown" | "empty" | "blocked";
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

export interface RoundStart {
  round: number;
  letter: string;
  category: { id: string; name: string };
  deadline: number;
  serverNow: number;
}

export interface VoteStart {
  round: number;
  items: Array<{ playerId: string; nickname: string; answer: string }>;
  deadline: number;
  serverNow: number;
}

export interface Standing {
  id: string;
  nickname: string;
  score: number;
  strikes: number;
  eliminated: boolean;
}

export interface GameEnd {
  winners: string[];
  standings: Standing[];
}

/** Codes a well-behaved client can get in a normal game: a late answer, an eliminated player. */
export const EXPECTED_ERRORS: Record<string, readonly string[]> = {
  "answer:submit": ["too_late", "not_accepting", "not_playing"],
  "vote:cast": ["too_late", "not_voting", "not_allowed", "not_found"],
};
