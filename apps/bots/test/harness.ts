// For the integration tests: the real game server (apps/game/dist, as `make game` builds it) as
// separate processes, and a fake validator that judges answers by the repo's word lists.
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const GAME_MAIN = fileURLToPath(new URL("../../game/dist/main.js", import.meta.url));
export const WORDS_DIR = fileURLToPath(new URL("../../../data/categories", import.meta.url));
export const ORIGIN = "https://bots.test";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * The validator's two endpoints. A listed word is valid; an answer that starts with the round's
 * letter but isn't listed is unknown, so it goes to the room vote; anything else is invalid.
 */
export async function startFakeValidator(): Promise<{ url: string; validations: () => number; close: () => Promise<void> }> {
  const categories = readdirSync(WORDS_DIR)
    .filter((f) => f.endsWith(".json"))
    .map((f) => JSON.parse(readFileSync(join(WORDS_DIR, f), "utf8")) as { id: string; name: string; lists: Array<{ words: string[] }> });
  const words = new Map(categories.map((c) => [c.id, new Set(c.lists.flatMap((l) => l.words))]));
  const playable = categories.map((c) => {
    const counts = new Map<string, number>();
    for (const w of words.get(c.id)!) counts.set([...w][0]!, (counts.get([...w][0]!) ?? 0) + 1);
    return { id: c.id, name: c.name, kind: "regular", letters: [...counts].filter(([, n]) => n >= 3).map(([l]) => l).sort() };
  });
  let validations = 0;
  const server: Server = createServer((req, res) => {
    const send = (code: number, body: unknown) => {
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.method === "GET" && req.url === "/v1/categories") return send(200, { categories: playable });
    if (req.method !== "POST" || req.url !== "/v1/validate") return send(404, { error: "not_found" });
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      validations++;
      const { category, letter, answer } = JSON.parse(body) as { category: string; letter: string; answer: string };
      const listed = words.get(category)?.has(answer) ?? false;
      send(200, { result: listed ? "valid" : answer.startsWith(letter) ? "unknown" : "invalid", key: answer });
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    validations: () => validations,
    close: () => new Promise((r) => server.close(() => r())),
  };
}

async function freePort(): Promise<number> {
  const s = createServer();
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  const port = (s.address() as AddressInfo).port;
  await new Promise((r) => s.close(r));
  return port;
}

export interface GamePod {
  name: string;
  url: string;
  proc: ChildProcess;
  logs: string[];
  exited: Promise<number | null>;
}

/** Starts `node apps/game/dist/main.js` and waits until it's ready. */
export async function startGamePod(name: string, env: Record<string, string>): Promise<GamePod> {
  if (!existsSync(GAME_MAIN)) throw new Error(`${GAME_MAIN} doesn't exist: build the game first (make game)`);
  const port = await freePort();
  const proc = spawn(process.execPath, [GAME_MAIN], {
    env: { ...process.env, ...env, GAME_PORT: String(port), GIT_SHA: "unknown" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const logs: string[] = [];
  proc.stdout!.on("data", (d: Buffer) => logs.push(...d.toString().split("\n").filter(Boolean)));
  proc.stderr!.on("data", (d: Buffer) => logs.push(...d.toString().split("\n").filter(Boolean)));
  const exited = new Promise<number | null>((r) => proc.once("exit", (code) => r(code)));
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 300; i++) {
    if (proc.exitCode !== null) throw new Error(`game pod ${name} exited ${proc.exitCode}: ${logs.slice(-5).join(" | ")}`);
    try {
      if ((await fetch(`${url}/readyz`)).status === 200) return { name, url, proc, logs, exited };
    } catch {
      // not listening yet
    }
    await sleep(100);
  }
  proc.kill("SIGKILL");
  throw new Error(`game pod ${name} never became ready: ${logs.slice(-5).join(" | ")}`);
}

export async function stopGamePod(pod: GamePod, signal: NodeJS.Signals = "SIGKILL"): Promise<number | null> {
  if (pod.proc.exitCode === null && pod.proc.signalCode === null) pod.proc.kill(signal);
  return pod.exited;
}
