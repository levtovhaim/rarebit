// A seeded random number generator (mulberry32), so a run with --seed plays the same answers
// and votes again. Not for anything security-related.
export type Rng = () => number;

export function seededRng(seed: number): Rng {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A new generator for each bot, derived from the run's, so bots don't share one sequence. */
export function fork(rng: Rng): Rng {
  return seededRng(Math.floor(rng() * 2 ** 32));
}

export function pick<T>(rng: Rng, items: readonly T[]): T | undefined {
  return items.length === 0 ? undefined : items[Math.floor(rng() * items.length)];
}
