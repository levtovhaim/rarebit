// Test helpers: game servers as in-process "pods" against one Redis, and Socket.IO clients.
import { io as connect, type Socket } from "socket.io-client";
import { createGameServer, type GameServer } from "../src/app.js";
import { loadConfig, type Config } from "../src/config.js";
import { createLogger } from "../src/log.js";
import type { ValidatorClient } from "../src/validator.js";

export const REDIS_URL = process.env.TEST_REDIS_URL ?? "";

export function testConfig(over: Record<string, string> = {}): Config {
  return loadConfig({
    REDIS_URL,
    VALIDATOR_URL: "http://127.0.0.1:1", // unused: the tests pass a fake validator
    ALLOWED_ORIGINS: "*",
    TRUSTED_PROXY_HOPS: "0", // the tests connect directly
    ROUND_SECONDS: "3",
    VOTE_SECONDS: "2",
    RESULTS_SECONDS: "1",
    MAX_ROUNDS: "2",
    QUICKPLAY_MIN_PLAYERS: "3",
    QUICKPLAY_COUNTDOWN_SECONDS: "1",
    DRAIN_DELAY_SECONDS: "1",
    LOG_LEVEL: "error",
    ...over,
  });
}

/** One category, one letter, and fixed verdicts. */
export const fakeValidator: ValidatorClient = {
  async categories() {
    return [{ id: "country", name: "ארץ", letters: ["א"] }];
  },
  async validate(_category, _letter, answer) {
    if (answer === "אוסטריה" || answer === "אסטריה") return { result: "valid", key: "אוסטריה" };
    if (answer === "ארגנטינה") return { result: "valid", key: "ארגנטינה" };
    if (answer === "אטלנטיס") return { result: "unknown", key: "אטלנטיס" };
    return { result: "invalid", key: answer };
  },
};

export interface Pod {
  server: GameServer;
  port: number;
  name: string;
}

export async function startPod(name: string, config = testConfig()): Promise<Pod> {
  const server = createGameServer(config, createLogger("error", "test"), { validator: fakeValidator, podId: name });
  const port = await server.start(0);
  return { server, port, name };
}

export async function client(pod: Pod): Promise<Socket> {
  const socket = connect(`http://127.0.0.1:${pod.port}`, { transports: ["websocket"], reconnection: false, forceNew: true });
  await new Promise<void>((resolve, reject) => {
    socket.once("connect", () => resolve());
    socket.once("connect_error", (err) => {
      socket.disconnect();
      reject(err);
    });
  });
  return socket;
}

/** An acknowledgement: { ok: true, ...fields } or { ok: false, error }. */
export type Reply = { ok: boolean; error?: string; [key: string]: any };

export async function call(socket: Socket, event: string, payload: object = {}): Promise<Reply> {
  return (await socket.timeout(5000).emitWithAck(event, payload)) as Reply;
}

/** The next `event` on `socket` that matches `when`. */
export function next(socket: Socket, event: string, when: (p: any) => boolean = () => true, timeoutMs = 12_000): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off(event, listener);
      reject(new Error(`no ${event} within ${timeoutMs} ms`));
    }, timeoutMs);
    const listener = (payload: unknown) => {
      if (!when(payload)) return;
      clearTimeout(timer);
      socket.off(event, listener);
      resolve(payload);
    };
    socket.on(event, listener);
  });
}
