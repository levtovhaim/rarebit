// The command line, checked once: a bad value stops the run with every problem listed (exit 2),
// before any bot connects. Each option can also come from an environment variable, for Jobs.
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import type { Level } from "./log.js";
import { strategyNames } from "./strategy.js";

export const MODES = ["synthetic", "load", "observe"] as const;
export type Mode = (typeof MODES)[number];

export interface Config {
  mode: Mode;
  urls: string[];
  socketPath: string;
  origin: string | undefined;
  wordsDir: string;
  gameMode: "private" | "quickplay";
  players: number;
  rooms: number;
  games: number;
  durationS: number;
  timeoutS: number;
  stallGraceS: number;
  rampMs: number;
  maxFailed: number;
  strategy: string;
  seed: number | undefined;
  ackTimeoutMs: number;
  reconnectGiveUpS: number;
  logLevel: Level;
}

export const USAGE = `usage: bots <synthetic|load|observe> --url <url>[,<url>...] [options]

  synthetic   one game; exit 0 if it finished correctly, 1 if not (black-box monitoring)
  load        --rooms games at once, --games each, one after another; a report at the end
  observe     games in --rooms rooms, back to back, for --duration seconds or until stopped;
              every game's result as it ends (the chaos observer)

  --url            the game's base URL(s), comma-separated     BOTS_URL
  --socket-path    the Socket.IO path (/socket.io)             BOTS_SOCKET_PATH
  --origin         the Origin header to send                   BOTS_ORIGIN
  --words          the word lists (data/categories)            BOTS_WORDS_DIR
  --game-mode      private | quickplay (private)               BOTS_GAME_MODE
  --players        bots per game, 2-8 (3)                      BOTS_PLAYERS
  --rooms          games at once, 1-1000 (1)                   BOTS_ROOMS
  --games          load: games per room, 1-100000 (1)          BOTS_GAMES
  --duration       observe: seconds, 1-86400 (300)             BOTS_DURATION
  --timeout        seconds a game may take, 10-7200 (900)      BOTS_TIMEOUT
  --stall-grace    seconds a phase may sit past its deadline, 5-600 (30)   BOTS_STALL_GRACE
  --ramp           ms between starting rooms, 0-60000 (100)    BOTS_RAMP
  --max-failed     failed games tolerated, 0-100000 (0)        BOTS_MAX_FAILED
  --strategy       ${strategyNames.join(" | ")} (scripted)                         BOTS_STRATEGY
  --seed           an integer, for a run that repeats          BOTS_SEED
  --ack-timeout    ms to wait for a reply, 100-60000 (5000)    BOTS_ACK_TIMEOUT
  --reconnect-give-up  seconds to keep reconnecting, 1-600 (30)  BOTS_RECONNECT_GIVE_UP
  --log-level      debug | info | warn | error (info)          BOTS_LOG_LEVEL

Exit: 0 every game finished correctly (or at most --max-failed didn't); 1 otherwise; 2 bad options.`;

export class ConfigError extends Error {}

/** data/categories at the repo root: src/ and dist/ are both one level below apps/bots. */
const DEFAULT_WORDS = fileURLToPath(new URL("../../../data/categories", import.meta.url));

export function loadConfig(argv: string[], env: Record<string, string | undefined>): Config {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      strict: true,
      options: Object.fromEntries(
        ["url", "socket-path", "origin", "words", "game-mode", "players", "rooms", "games", "duration", "timeout", "stall-grace", "ramp", "max-failed", "strategy", "seed", "ack-timeout", "reconnect-give-up", "log-level"].map((o) => [o, { type: "string" as const }]),
      ),
    });
  } catch (err) {
    throw new ConfigError(err instanceof Error ? err.message : String(err));
  }
  const problems: string[] = [];
  const opt = (name: string, envName: string): string | undefined => {
    const v = (parsed.values as Record<string, string | undefined>)[name] ?? env[envName];
    return v === "" ? undefined : v;
  };
  const int = (name: string, envName: string, def: number, min: number, max: number): number => {
    const raw = opt(name, envName);
    if (raw === undefined) return def;
    const n = Number(raw);
    if (!Number.isInteger(n) || n < min || n > max) {
      problems.push(`--${name}: must be an integer from ${min} to ${max}`);
      return def;
    }
    return n;
  };
  const oneOf = <T extends string>(name: string, envName: string, values: readonly T[], def: T): T => {
    const raw = opt(name, envName) ?? def;
    if (!values.includes(raw as T)) problems.push(`--${name}: must be one of ${values.join(", ")}`);
    return raw as T;
  };

  const [mode, ...extra] = parsed.positionals;
  if (!mode || !MODES.includes(mode as Mode)) problems.push(`the mode must be one of ${MODES.join(", ")}`);
  if (extra.length > 0) problems.push(`unexpected arguments: ${extra.join(" ")}`);

  const urls = (opt("url", "BOTS_URL") ?? "").split(",").map((u) => u.trim()).filter(Boolean);
  if (urls.length === 0) problems.push("--url: required");
  for (const u of urls) {
    try {
      if (!["http:", "https:"].includes(new URL(u).protocol)) throw new Error();
    } catch {
      problems.push("--url: each must be an http:// or https:// URL");
      break;
    }
  }
  const socketPath = opt("socket-path", "BOTS_SOCKET_PATH") ?? "/socket.io";
  if (!/^\/[A-Za-z0-9/._-]*$/.test(socketPath)) problems.push("--socket-path: must be a path like /socket.io");
  const origin = opt("origin", "BOTS_ORIGIN");
  if (origin !== undefined) {
    try {
      if (new URL(origin).origin !== origin) throw new Error();
    } catch {
      problems.push("--origin: must be an origin like https://example.com");
    }
  }
  const seedRaw = opt("seed", "BOTS_SEED");
  let seed: number | undefined;
  if (seedRaw !== undefined) {
    seed = Number(seedRaw);
    if (!Number.isSafeInteger(seed)) problems.push("--seed: must be an integer");
  }

  const config: Config = {
    mode: mode as Mode,
    urls,
    socketPath,
    origin,
    wordsDir: opt("words", "BOTS_WORDS_DIR") ?? DEFAULT_WORDS,
    gameMode: oneOf("game-mode", "BOTS_GAME_MODE", ["private", "quickplay"] as const, "private"),
    players: int("players", "BOTS_PLAYERS", 3, 2, 8),
    rooms: int("rooms", "BOTS_ROOMS", 1, 1, 1000),
    games: int("games", "BOTS_GAMES", 1, 1, 100_000),
    durationS: int("duration", "BOTS_DURATION", 300, 1, 86_400),
    timeoutS: int("timeout", "BOTS_TIMEOUT", 900, 10, 7200),
    stallGraceS: int("stall-grace", "BOTS_STALL_GRACE", 30, 5, 600),
    rampMs: int("ramp", "BOTS_RAMP", 100, 0, 60_000),
    maxFailed: int("max-failed", "BOTS_MAX_FAILED", 0, 0, 100_000),
    strategy: oneOf("strategy", "BOTS_STRATEGY", strategyNames, "scripted"),
    seed,
    ackTimeoutMs: int("ack-timeout", "BOTS_ACK_TIMEOUT", 5000, 100, 60_000),
    reconnectGiveUpS: int("reconnect-give-up", "BOTS_RECONNECT_GIVE_UP", 30, 1, 600),
    logLevel: oneOf("log-level", "BOTS_LOG_LEVEL", ["debug", "info", "warn", "error"] as const, "info"),
  };
  if (config.gameMode === "quickplay" && config.mode !== "synthetic") {
    problems.push("--game-mode quickplay: only for synthetic (load and observe use private rooms, so games don't mix)");
  }
  if (problems.length > 0) throw new ConfigError(problems.join("; "));
  return config;
}
