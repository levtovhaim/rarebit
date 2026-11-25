// The bots against the real game server: two game processes (apps/game/dist) on one Redis, and a
// fake validator. `make bots-integration` starts a throwaway Redis and sets TEST_REDIS_URL;
// without it these tests are skipped. They cover the drills the bots exist for: a pod killed
// mid-round, a pod drained, and every pod gone (the run must fail, not hang).
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { GameDeps } from "../src/game.js";
import { playGame } from "../src/game.js";
import { silent } from "../src/log.js";
import { seededRng } from "../src/rng.js";
import { run, type Controls } from "../src/run.js";
import { Stats } from "../src/stats.js";
import { scripted, type Strategy } from "../src/strategy.js";
import { loadWords, wordsFor } from "../src/words.js";
import { ORIGIN, WORDS_DIR, startFakeValidator, startGamePod, stopGamePod, type GamePod } from "./harness.js";
import { loadConfig } from "../src/config.js";

const REDIS_URL = process.env.TEST_REDIS_URL ?? "";
const maybe = REDIS_URL ? describe : describe.skip;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const words = loadWords(WORDS_DIR);
const BOTS_MAIN = fileURLToPath(new URL("../dist/main.js", import.meta.url));
// Starting a game server loads its modules; from a Windows drive under WSL that alone takes ~10 s.
const HOOK_TIMEOUT_MS = 60_000;

/** One made-up answer per round (bot 1's, so the room votes on it), real words from the others, every vote yes. */
const voting: Strategy = {
  name: "voting",
  nickname: (i) => `בוט ${i + 1}`,
  answer: (ctx) =>
    ctx.me.index === 0
      ? { text: `${ctx.letter}זזזזז`, afterMs: 100 }
      : { text: wordsFor(ctx.words, ctx.category.id, ctx.letter)[ctx.me.index] ?? `${ctx.letter}ק`, afterMs: 200 },
  vote: () => true,
};

maybe("the bots against the game server", { timeout: 180_000 }, () => {
  let validator: Awaited<ReturnType<typeof startFakeValidator>>;
  const pods: Record<"a" | "b", GamePod | null> = { a: null, b: null };
  let env: Record<string, string>;

  const pod = async (name: "a" | "b") => (pods[name] ??= await startGamePod(name, env));
  const kill = async (name: "a" | "b", signal: NodeJS.Signals = "SIGKILL") => {
    const p = pods[name];
    pods[name] = null;
    return p ? stopGamePod(p, signal) : null;
  };
  const deps = (urls: string[], over: Partial<GameDeps> = {}): GameDeps => ({
    urls,
    socketPath: "/socket.io",
    origin: ORIGIN,
    words,
    strategy: scripted(),
    log: silent,
    stats: new Stats(),
    rng: seededRng(1234),
    ackTimeoutMs: 3000,
    reconnectGiveUpMs: 20_000,
    ...over,
  });
  const spec = { mode: "private" as const, players: 3, timeoutMs: 60_000, stallGraceMs: 25_000, urlOffset: 0 };
  const controls = (): Controls => ({ stop: new AbortController().signal, abort: new AbortController().signal });
  /** Resolves once some bot has had an answer acknowledged: a round is running. */
  const roundRunning = async (stats: Stats) => {
    for (let i = 0; i < 200; i++) {
      if ((stats.summary().latency_ms["answer:submit"]?.n ?? 0) > 0) return;
      await sleep(50);
    }
    throw new Error("no round started");
  };

  beforeAll(async () => {
    validator = await startFakeValidator();
    env = {
      REDIS_URL,
      VALIDATOR_URL: validator.url,
      ALLOWED_ORIGINS: ORIGIN,
      ROUND_SECONDS: "3",
      VOTE_SECONDS: "2",
      RESULTS_SECONDS: "1",
      MAX_ROUNDS: "2",
      QUICKPLAY_MIN_PLAYERS: "3",
      QUICKPLAY_COUNTDOWN_SECONDS: "1",
      DRAIN_DELAY_SECONDS: "1",
      SHUTDOWN_TIMEOUT_SECONDS: "5",
      MAX_CONNECTIONS_PER_IP: "500",
      LOG_LEVEL: "warn",
    };
    await Promise.all([pod("a"), pod("b")]);
  }, HOOK_TIMEOUT_MS);

  afterEach(async () => {
    await Promise.all([pod("a"), pod("b")]); // a test that killed a pod gets it back for the next
  }, HOOK_TIMEOUT_MS);

  afterAll(async () => {
    await Promise.all([kill("a"), kill("b")]);
    await validator?.close();
  }, HOOK_TIMEOUT_MS);

  it("plays a whole private game, with a vote, and the scores add up", async () => {
    const d = deps([(await pod("a")).url], { strategy: voting });
    const report = await playGame(d, spec);
    expect(report, JSON.stringify(report)).toMatchObject({ ok: true, rounds: 2, checks: { ended: true, winners_agree: true, scores: "ok" } });
    expect(report.unexpected_errors).toEqual([]);
    expect(d.stats.summary().latency_ms["vote:cast"]?.n).toBeGreaterThanOrEqual(4); // two voters, two rounds
    expect(report.winners).toHaveLength(3); // everyone scored 10 each round
  });

  it("plays a quick-play game: the bots meet in one public room", async () => {
    const report = await playGame(deps([(await pod("a")).url, (await pod("b")).url]), { ...spec, mode: "quickplay" });
    expect(report, JSON.stringify(report)).toMatchObject({ ok: true, rounds: 2 });
    expect(report.room).toMatch(/^[A-Z0-9]{6}$/);
  });

  it("runs several games at once, each room's bots spread over both pods", async () => {
    const d = deps([(await pod("a")).url, (await pod("b")).url]);
    const config = loadConfig(["load", "--url", "http://x", "--rooms", "4", "--games", "1", "--ramp", "50", "--timeout", "120"], {});
    const summary = await run(config, d, controls(), silent);
    expect(summary, JSON.stringify(summary)).toMatchObject({ games: 4, ok: 4, failed: 0, passed: true, reconnects: 0 });
    expect(summary.latency_ms["answer:submit"]?.n).toBeGreaterThan(0);
    expect(summary.latency_ms["room:create"]?.n).toBe(4);
  });

  it("finishes every game when a pod is killed mid-round", async () => {
    const d = deps([(await pod("a")).url, (await pod("b")).url]);
    const config = loadConfig(["load", "--url", "http://x", "--rooms", "3", "--games", "1", "--ramp", "0", "--timeout", "120"], {});
    const running = run(config, d, controls(), silent);
    await roundRunning(d.stats);
    await kill("a", "SIGKILL");
    const summary = await running;
    expect(summary, JSON.stringify(summary)).toMatchObject({ games: 3, ok: 3, failed: 0, passed: true });
    expect(summary.resumes).toBeGreaterThan(0);
  });

  it("finishes every game when a pod drains", async () => {
    const d = deps([(await pod("a")).url, (await pod("b")).url]);
    const config = loadConfig(["load", "--url", "http://x", "--rooms", "2", "--games", "1", "--ramp", "0", "--timeout", "120"], {});
    const running = run(config, d, controls(), silent);
    await roundRunning(d.stats);
    const exit = kill("a", "SIGTERM");
    const summary = await running;
    expect(await exit).toBe(0);
    expect(summary, JSON.stringify(summary)).toMatchObject({ games: 2, ok: 2, passed: true });
    expect(summary.counts.draining_notices).toBeGreaterThan(0);
  });

  it("fails, and doesn't hang, when every pod is gone", async () => {
    const d = deps([(await pod("a")).url, (await pod("b")).url], { reconnectGiveUpMs: 3000 });
    const started = Date.now();
    const game = playGame(d, spec);
    await roundRunning(d.stats);
    await Promise.all([kill("a"), kill("b")]);
    const report = await game;
    expect(report.ok).toBe(false);
    expect(report.failure).toMatch(/couldn't reconnect/);
    expect(Date.now() - started).toBeLessThan(30_000);
  });

  it("fails at once, with the connect error, from an origin the game doesn't allow", async () => {
    const report = await playGame(deps([(await pod("a")).url], { origin: "https://elsewhere.test" }), spec);
    expect(report.ok).toBe(false);
    expect(report.failure).toBe("websocket error");
    expect(report.duration_ms).toBeLessThan(5000);
  });

  it("works as a command: synthetic exits 0 with a summary line; bad options exit 2", async () => {
    const cli = (args: string[]) =>
      new Promise<{ code: number | null; out: string }>((resolve) => {
        const p = spawn(process.execPath, [BOTS_MAIN, ...args], { stdio: ["ignore", "pipe", "pipe"] });
        let out = "";
        p.stdout.on("data", (d: Buffer) => (out += d));
        p.stderr.on("data", (d: Buffer) => (out += d));
        p.on("exit", (code) => resolve({ code, out }));
      });
    const ok = await cli(["synthetic", "--url", (await pod("b")).url, "--origin", ORIGIN, "--seed", "7"]);
    expect(ok.code, ok.out).toBe(0);
    const lines = ok.out.trim().split("\n").map((l) => JSON.parse(l) as Record<string, unknown>);
    expect(lines.at(-1)).toMatchObject({ msg: "summary", passed: true, games: 1, ok: 1 });
    expect(lines.find((l) => l.msg === "game")).toMatchObject({ ok: true, rounds: 2 });
    const bad = await cli(["synthetic", "--players", "12"]);
    expect(bad.code).toBe(2);
    expect(bad.out).toContain("invalid options");
    expect(bad.out).toContain("--url: required");
  });
});
