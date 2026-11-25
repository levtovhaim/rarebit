// Where the app lives: at / or under a path prefix (a path-based preview serves it at /pr-12/).
// Everything is relative to the page, so one build works anywhere.
import { ROOM_CODE } from "./protocol";

/** The directory the page was served from: "/" or "/pr-12/". */
export function basePath(pathname: string): string {
  return pathname.slice(0, pathname.lastIndexOf("/") + 1) || "/";
}

/** The game's Socket.IO path behind the same prefix (the game's SOCKET_PATH must match). */
export function socketPath(base: string): string {
  return `${base}socket.io`;
}

/** The link a QR code or a share sheet carries: this page, with the room code. */
export function joinLink(origin: string, base: string, code: string): string {
  return `${origin}${base}?room=${encodeURIComponent(code)}`;
}

/** The room code from a join link's query, if it's a well-formed one. */
export function roomFromSearch(search: string): string | null {
  const code = new URLSearchParams(search).get("room")?.trim().toUpperCase() ?? "";
  return ROOM_CODE.test(code) ? code : null;
}

/** A room code as typed: upper case, without spaces or dashes. */
export function normalizeCode(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, "").slice(0, 6);
}
