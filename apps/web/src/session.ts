// The seat, kept in localStorage so a reload or a dropped connection gets the player back into
// their room. Storage can be missing or throw (private windows, blocked storage): the game still
// works, only a reload loses the seat.
import type { Seat } from "./store";

const SEAT = "rarebit.seat";
const NICKNAME = "rarebit.nickname";

function read(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function write(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // no storage: nothing to keep
  }
}

export function loadSeat(): Seat | null {
  try {
    const s = JSON.parse(read(SEAT) ?? "null") as Partial<Seat> | null;
    return s && s.roomCode && s.playerId && s.token && s.nickname ? (s as Seat) : null;
  } catch {
    return null;
  }
}

export function saveSeat(seat: Seat | null): void {
  write(SEAT, seat ? JSON.stringify(seat) : null);
}

export function loadNickname(): string {
  return read(NICKNAME) ?? "";
}

export function saveNickname(nickname: string): void {
  write(NICKNAME, nickname);
}
