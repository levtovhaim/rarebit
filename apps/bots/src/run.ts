// The three modes. Each prints every finished game as a "game" line and ends with a "summary"
// line; the exit code says whether the run passed.
import type { Config } from "./config.js";
import { playGame, type GameDeps, type GameReport } from "./game.js";
import type { Logger } from "./log.js";
import { percentiles, type Stats } from "./stats.js";

export interface Controls {
  /** No new games after this; running ones finish. */
  stop: AbortSignal;
  /** Running games end now, as aborted. */
  abort: AbortSignal;
}

export interface Summary {
  mode: Config["mode"];
  games: number;
  ok: number;
  failed: number;
  aborted: number;
  passed: boolean;
  duration_ms: number;
  failures: Array<{ room: string | null; failure: string | null }>;
  game_ms: ReturnType<typeof percentiles>;
  reconnects: number;
  resumes: number;
  latency_ms: ReturnType<Stats["summary"]>["latency_ms"];
  counts: ReturnType<Stats["summary"]>["counts"];
}

const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const t = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => (clearTimeout(t), resolve()), { once: true });
  });

export async function run(config: Config, deps: GameDeps, controls: Controls, log: Logger): Promise<Summary> {
  const started = Date.now();
  const reports: GameReport[] = [];
  const spec = (urlOffset: number) => ({
    mode: config.gameMode,
    players: config.players,
    timeoutMs: config.timeoutS * 1000,
    stallGraceMs: config.stallGraceS * 1000,
    urlOffset,
    signal: controls.abort,
  });
  const record = (r: GameReport) => {
    reports.push(r);
    const line = { ...r };
    if (r.ok || r.aborted) log.info("game", line);
    else log.warn("game", line);
  };

  if (config.mode === "synthetic") {
    // A synthetic run that's told to stop has no result: it aborts at once.
    record(await playGame(deps, { ...spec(0), signal: AbortSignal.any([controls.stop, controls.abort]) }));
  } else {
    const until = config.mode === "observe" ? started + config.durationS * 1000 : Infinity;
    const perRoom = config.mode === "load" ? config.games : Infinity;
    await Promise.all(
      Array.from({ length: config.rooms }, async (_, room) => {
        await sleep(room * config.rampMs, controls.stop);
        for (let g = 0; g < perRoom && !controls.stop.aborted && Date.now() < until; g++) {
          record(await playGame(deps, spec(room * config.players)));
        }
      }),
    );
  }

  const ok = reports.filter((r) => r.ok).length;
  const aborted = reports.filter((r) => r.aborted).length;
  const failed = reports.length - ok - aborted;
  const stats = deps.stats.summary();
  const passed = config.mode === "synthetic" ? ok === 1 : failed <= config.maxFailed && ok > 0;
  return {
    mode: config.mode,
    games: reports.length,
    ok,
    failed,
    aborted,
    passed,
    duration_ms: Date.now() - started,
    failures: reports.filter((r) => !r.ok && !r.aborted).slice(0, 20).map((r) => ({ room: r.room, failure: r.failure })),
    game_ms: percentiles(reports.filter((r) => r.ok).map((r) => r.duration_ms)),
    reconnects: reports.reduce((n, r) => n + r.reconnects, 0),
    resumes: reports.reduce((n, r) => n + r.resumes, 0),
    latency_ms: stats.latency_ms,
    counts: stats.counts,
  };
}
