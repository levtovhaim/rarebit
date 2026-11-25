// Time on the server's clock. Deadlines are epoch ms on the server (Redis's clock, ADR 0021);
// the UI keeps the offset from the last serverNow it saw and never trusts the phone's clock.

/** The server's clock minus ours, from a payload's serverNow and when it arrived. */
export function clockOffset(serverNow: number, receivedAt: number): number {
  return serverNow - receivedAt;
}

/** Milliseconds left until a server deadline. */
export function remainingMs(deadline: number, offset: number, now: number): number {
  return Math.max(0, deadline - (now + offset));
}

export interface Squares {
  /** How many squares the timer draws. */
  total: number;
  /** How many of them are crossed out. */
  crossed: number;
  /** Seconds left, rounded up, as the big number shows them. */
  seconds: number;
  /** The last 5 seconds. */
  urgent: boolean;
}

/**
 * The notebook-squares timer: one square per second of the phase (fewer, each worth more, for
 * long phases), crossed out as time passes.
 */
export function squares(phaseMs: number, leftMs: number, maxSquares = 30): Squares {
  const seconds = Math.ceil(leftMs / 1000);
  const phase = Math.max(phaseMs, leftMs, 1);
  const total = Math.max(1, Math.min(maxSquares, Math.ceil(phase / 1000)));
  const perSquare = phase / total;
  const crossed = Math.min(total, Math.floor((phase - leftMs) / perSquare));
  return { total, crossed, seconds, urgent: leftMs > 0 && seconds <= 5 };
}
