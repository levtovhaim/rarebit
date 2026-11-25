// What a run measures: acknowledgement latency per event, game durations, reconnects, resumes
// and error codes. Kept in memory and reported as percentiles at the end.
export class Stats {
  private readonly samples = new Map<string, number[]>();
  private readonly counters = new Map<string, number>();

  observe(name: string, ms: number): void {
    const list = this.samples.get(name);
    if (list) list.push(ms);
    else this.samples.set(name, [ms]);
  }

  count(name: string, by = 1): void {
    this.counters.set(name, (this.counters.get(name) ?? 0) + by);
  }

  get(name: string): number {
    return this.counters.get(name) ?? 0;
  }

  summary(): { latency_ms: Record<string, Percentiles>; counts: Record<string, number> } {
    const latency: Record<string, Percentiles> = {};
    for (const [name, values] of [...this.samples].sort(([a], [b]) => a.localeCompare(b))) latency[name] = percentiles(values);
    return { latency_ms: latency, counts: Object.fromEntries([...this.counters].sort(([a], [b]) => a.localeCompare(b))) };
  }
}

export interface Percentiles {
  n: number;
  p50: number;
  p95: number;
  p99: number;
  max: number;
}

/** Nearest-rank percentiles, rounded to 0.1 ms. */
export function percentiles(values: number[]): Percentiles {
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (p: number) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))] ?? 0;
  const round = (v: number) => Math.round(v * 10) / 10;
  return { n: sorted.length, p50: round(rank(50)), p95: round(rank(95)), p99: round(rank(99)), max: round(sorted.at(-1) ?? 0) };
}
