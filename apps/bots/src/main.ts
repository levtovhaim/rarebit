// The bots command: bots <synthetic|load|observe> --url <url> [options] (config.ts has them all).
// SIGTERM or SIGINT: no new games, running ones finish (a synthetic run aborts at once); a
// second signal aborts the running games too.
import { ConfigError, USAGE, loadConfig } from "./config.js";
import { createLogger } from "./log.js";
import { seededRng } from "./rng.js";
import { run } from "./run.js";
import { Stats } from "./stats.js";
import { strategyByName } from "./strategy.js";
import { loadWords } from "./words.js";

const version = process.env.GIT_SHA || "unknown";

let config;
try {
  config = loadConfig(process.argv.slice(2), process.env);
} catch (err) {
  const message = err instanceof ConfigError ? err.message : String(err);
  createLogger("info", { version }).error("invalid options", { err: message });
  process.stderr.write(USAGE + "\n");
  process.exit(2);
}

const log = createLogger(config.logLevel, { version, mode: config.mode });
let words;
try {
  words = loadWords(config.wordsDir);
} catch (err) {
  log.error("can't read the word lists", { err: String(err), dir: config.wordsDir });
  process.exit(2);
}

const seed = config.seed ?? Math.floor(Math.random() * 2 ** 31);
const stop = new AbortController();
const abort = new AbortController();
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    if (!stop.signal.aborted) {
      log.info("stopping: no new games", { signal });
      stop.abort();
    } else {
      log.warn("second signal: aborting the running games", { signal });
      abort.abort();
    }
  });
}

log.info("starting", { urls: config.urls.length, players: config.players, rooms: config.rooms, strategy: config.strategy, seed });
const summary = await run(
  config,
  {
    urls: config.urls,
    socketPath: config.socketPath,
    origin: config.origin,
    words,
    strategy: strategyByName(config.strategy),
    log,
    stats: new Stats(),
    rng: seededRng(seed),
    ackTimeoutMs: config.ackTimeoutMs,
    reconnectGiveUpMs: config.reconnectGiveUpS * 1000,
  },
  { stop: stop.signal, abort: abort.signal },
  log,
);
(summary.passed ? log.info : log.error)("summary", { ...summary });
// Exit once the lines are written out: writes to a pipe can be asynchronous.
process.stdout.write("", () => process.exit(summary.passed ? 0 : 1));
