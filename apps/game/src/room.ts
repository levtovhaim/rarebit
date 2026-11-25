// The room as stored in Redis, and the part of it clients see.
import type { Evaluated, Player, Verdict } from "./rules.js";

export type RoomType = "private" | "public";

/**
 * lobby → countdown → round → (voting) → results → round → ... → ended.
 * A private room's host moves it from lobby to countdown; a public room moves when enough
 * players have joined. Every phase but lobby and ended has a deadline in Redis.
 */
export type Phase = "lobby" | "countdown" | "round" | "voting" | "results" | "ended";

export interface CategoryRef {
  id: string;
  name: string;
}

export interface PendingAnswer extends Evaluated {
  nickname: string;
}

export interface ResultLine {
  playerId: string;
  nickname: string;
  answer: string;
  verdict: Verdict;
  final: "valid" | "invalid";
  points: number;
  strike: boolean;
}

export interface RoundResult {
  round: number;
  letter: string;
  category: CategoryRef;
  answers: ResultLine[];
}

export interface Room {
  code: string;
  type: RoomType;
  phase: Phase;
  hostId: string | null;
  players: Player[];
  maxRounds: number;
  createdAt: number;
  startedAt: number | null;
  round: number;
  letter: string | null;
  category: CategoryRef | null;
  /** When the current phase ends, in epoch milliseconds; null in lobby and ended. */
  deadline: number | null;
  /** "category:letter" pairs this game has played. */
  used: string[];
  /** Evaluated answers waiting for the vote to finish. */
  pending: PendingAnswer[] | null;
  lastResults: RoundResult | null;
  winners: string[] | null;
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

/** What every client in the room may see: no tokens, no answers of the running round. */
export interface RoomSnapshot {
  code: string;
  type: RoomType;
  phase: Phase;
  hostId: string | null;
  players: PublicPlayer[];
  round: number;
  maxRounds: number;
  letter: string | null;
  category: CategoryRef | null;
  deadline: number | null;
  serverNow: number;
  voting: Array<{ playerId: string; nickname: string; answer: string }> | null;
  lastResults: RoundResult | null;
  winners: string[] | null;
}

export function snapshot(room: Room, now: number): RoomSnapshot {
  return {
    code: room.code,
    type: room.type,
    phase: room.phase,
    hostId: room.hostId,
    players: room.players.map(({ id, nickname, score, strikes, eliminated, left, connected }) => ({
      id,
      nickname,
      score,
      strikes,
      eliminated,
      left,
      connected,
    })),
    round: room.round,
    maxRounds: room.maxRounds,
    letter: room.letter,
    category: room.category,
    deadline: room.deadline,
    serverNow: now,
    voting:
      room.phase === "voting" && room.pending
        ? room.pending
            .filter((p) => p.verdict === "unknown")
            .map(({ playerId, nickname, answer }) => ({ playerId, nickname, answer }))
        : null,
    lastResults: room.lastResults,
    winners: room.winners,
  };
}
