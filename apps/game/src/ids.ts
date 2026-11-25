// Room codes, player ids and resume tokens.
import { createHash, randomBytes, randomInt, randomUUID } from "node:crypto";

// No 0/O, 1/I/L: a code is read aloud and typed on phones.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const ROOM_CODE = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$/;

export function roomCode(): string {
  let code = "";
  for (let i = 0; i < 6; i++) code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  return code;
}

export function playerId(): string {
  return randomUUID();
}

/** A resume token: the player keeps it; Redis keeps only its hash. */
export function token(): string {
  return randomBytes(24).toString("base64url");
}

export function tokenHash(t: string): string {
  return createHash("sha256").update(t).digest("hex");
}
