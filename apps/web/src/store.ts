// The UI's state, changed only by this reducer. The room snapshot from the server is the truth
// (ADR 0020): the reducer adds what the server doesn't keep for this player (the connection, the
// answer being typed, the votes cast) and forgets it when a new round begins.
import { clockOffset } from "./clock";
import type { RoomSnapshot } from "./protocol";

export interface Seat {
  roomCode: string;
  playerId: string;
  token: string;
  nickname: string;
}

export type Connection = "offline" | "connecting" | "online" | "reconnecting";

export interface State {
  connection: Connection;
  /** Why we're reconnecting: the connection dropped, or the server is being replaced. */
  reconnectReason: "dropped" | "draining" | null;
  seat: Seat | null;
  room: RoomSnapshot | null;
  /** Server clock minus ours. */
  offset: number;
  /** The current phase's length, for the timer: the deadline it was measured for, and its ms. */
  phase: { deadline: number; ms: number } | null;
  /** The answer this player sent in the current round. */
  sent: { round: number; text: string } | null;
  /** Votes this player cast in the current round: answer owner -> accept. */
  votes: { round: number; byOwner: Record<string, boolean> };
  /** An error code to show, until the next action. */
  error: string | null;
  /** We couldn't get back into the room (resume refused). */
  lost: boolean;
}

export type Action =
  | { type: "connecting" }
  | { type: "online" }
  | { type: "reconnecting"; reason: "dropped" | "draining" }
  | { type: "seated"; seat: Seat; room: RoomSnapshot; receivedAt: number }
  | { type: "state"; room: RoomSnapshot; receivedAt: number }
  | { type: "token"; token: string }
  | { type: "answered"; round: number; text: string }
  | { type: "voted"; round: number; owner: string; accept: boolean }
  | { type: "error"; code: string }
  | { type: "clearError" }
  | { type: "lost" }
  | { type: "left" };

export const initialState: State = {
  connection: "offline",
  reconnectReason: null,
  seat: null,
  room: null,
  offset: 0,
  phase: null,
  sent: null,
  votes: { round: 0, byOwner: {} },
  error: null,
  lost: false,
};

function withRoom(state: State, room: RoomSnapshot, receivedAt: number): State {
  const offset = clockOffset(room.serverNow, receivedAt);
  // A new deadline is a new phase: its length is measured once, when it first arrives.
  const phase =
    room.deadline === null
      ? null
      : state.phase?.deadline === room.deadline
        ? state.phase
        : { deadline: room.deadline, ms: Math.max(0, room.deadline - room.serverNow) };
  const newRound = state.room?.round !== room.round;
  return {
    ...state,
    room,
    offset,
    phase,
    sent: newRound ? null : state.sent,
    votes: state.votes.round === room.round ? state.votes : { round: room.round, byOwner: {} },
  };
}

export function reducer(state: State, action: Action): State {
  switch (action.type) {
    case "connecting":
      return { ...state, connection: "connecting" };
    case "online":
      return { ...state, connection: "online", reconnectReason: null };
    case "reconnecting":
      return { ...state, connection: "reconnecting", reconnectReason: action.reason };
    case "seated":
      return { ...withRoom({ ...state, sent: null, phase: null }, action.room, action.receivedAt), seat: action.seat, error: null, lost: false };
    case "state":
      // A snapshot for another room (a late push from one we left) is ignored.
      if (state.seat && action.room.code !== state.seat.roomCode) return state;
      return withRoom(state, action.room, action.receivedAt);
    case "token":
      return state.seat ? { ...state, seat: { ...state.seat, token: action.token } } : state;
    case "answered":
      return { ...state, sent: { round: action.round, text: action.text }, error: null };
    case "voted":
      return {
        ...state,
        error: null,
        votes: {
          round: action.round,
          byOwner: { ...(state.votes.round === action.round ? state.votes.byOwner : {}), [action.owner]: action.accept },
        },
      };
    case "error":
      return { ...state, error: action.code };
    case "clearError":
      return { ...state, error: null };
    case "lost":
      return { ...state, lost: true, seat: null, room: null, phase: null };
    case "left":
      return { ...initialState, connection: state.connection };
  }
}

/** This player's line in the room, if seated. */
export function me(state: State) {
  return state.room?.players.find((p) => p.id === state.seat?.playerId) ?? null;
}
