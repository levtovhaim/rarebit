// Builds one game server: HTTP runtime endpoints, Socket.IO on the same port, the Redis clients,
// the sweeper that advances rooms, and the drain on shutdown. main.ts runs one; the integration
// tests run several against the same Redis, as separate "pods".
import { createServer, type IncomingMessage, type Server as HttpServer } from "node:http";
import { hostname } from "node:os";
import { randomBytes } from "node:crypto";
import type { AddressInfo } from "node:net";
import { createAdapter } from "@socket.io/redis-adapter";
import { createClient } from "redis";
import { Server } from "socket.io";
import type { Config } from "./config.js";
import { createEngine, GRACE_MS } from "./engine.js";
import type { Logger } from "./log.js";
import { createMetrics } from "./metrics.js";
import { attachSockets } from "./socket.js";
import { createStore } from "./store.js";
import { createValidatorClient, type ValidatorClient } from "./validator.js";

const SWEEP_MS = 200;
const LEASE_MS = 15_000; // longer than the slowest evaluation: 8 validator calls with a retry
const PRUNE_MS = 60_000;
const READY_TIMEOUT_MS = 1000;
const MAX_HTTP_BUFFER = 16 * 1024;

export interface GameServer {
  http: HttpServer;
  io: Server;
  /** Listens, then connects to Redis; readiness stays false until Redis answers. */
  start(port: number): Promise<number>;
  /** The shutdown sequence (README → Drain). Resolves when everything is closed. */
  drain(): Promise<void>;
  close(): Promise<void>;
}

export function createGameServer(config: Config, log: Logger, opts: { validator?: ValidatorClient; podId?: string } = {}): GameServer {
  const podId = opts.podId ?? `${hostname()}-${randomBytes(3).toString("hex")}`;
  let draining = false;
  let redisReady = false;

  const redis = createClient({
    url: config.REDIS_URL,
    // RESP2, as the Socket.IO Redis adapter expects (node-redis 6 defaults to RESP3).
    RESP: 2,
    // Fail commands at once while disconnected instead of queueing them behind a dead socket.
    disableOfflineQueue: true,
    pingInterval: 10_000,
    socket: { connectTimeout: 2000, reconnectStrategy: (retries: number) => Math.min(200 * (retries + 1), 2000) },
  });
  const sub = redis.duplicate();

  const store = createStore(redis, config.ROOM_TTL_SECONDS);
  const http = createServer();
  const io = new Server(http, {
    path: config.SOCKET_PATH,
    transports: ["websocket"],
    serveClient: false,
    maxHttpBufferSize: MAX_HTTP_BUFFER,
    pingInterval: 10_000,
    pingTimeout: 5_000,
    allowRequest: (req: IncomingMessage, callback) => {
      // Not while starting, draining or cut off from Redis: the player couldn't play here anyway.
      if (!redisReady || !redis.isReady || draining) return callback("not ready", false);
      const origin = req.headers.origin;
      const allowed = config.allowedOrigins.length === 0 || (origin !== undefined && config.allowedOrigins.includes(origin));
      callback(allowed ? null : "origin not allowed", allowed);
    },
  });

  const metrics = createMetrics({
    roomsActive: () => (redisReady ? store.activeRooms() : Promise.resolve({ private: 0, public: 0 })),
    queueLength: async () => {
      if (!redisReady) return 0;
      const open = await store.openQuickplayRoom();
      const room = open ? await store.getRoom(open) : null;
      return room && (room.phase === "lobby" || room.phase === "countdown") ? room.players.filter((p) => !p.left).length : 0;
    },
    playersConnected: () => io.engine.clientsCount,
    draining: () => draining,
  });
  for (const client of [redis, sub]) {
    client.on("error", (err: unknown) => {
      metrics.redisErrorsTotal.inc();
      log.warn({ err: String(err) }, "redis error");
    });
  }

  const validator = opts.validator ?? createValidatorClient(config.VALIDATOR_URL, log, metrics);
  const engine = createEngine({
    store,
    validator,
    emit: (room, event, payload) => io.to(room).emit(event, payload),
    config,
    metrics,
    log,
  });
  attachSockets(io, engine, { metrics, log, draining: () => draining });

  // Runtime endpoints. Socket.IO answers its own path before this handler sees it.
  http.on("request", (req, res) => {
    if (req.url?.startsWith(config.SOCKET_PATH)) return;
    const send = (code: number, body: unknown, type = "application/json") => {
      res.writeHead(code, { "content-type": type });
      res.end(type === "application/json" ? JSON.stringify(body) : String(body));
    };
    if (req.method !== "GET") return send(405, { error: "method_not_allowed" });
    switch (req.url) {
      case "/healthz":
        return send(200, { status: "ok" });
      case "/readyz":
        if (draining) return send(503, { status: "draining" });
        return Promise.race([
          store.ping().then(() => true),
          new Promise<boolean>((resolve) => setTimeout(() => resolve(false), READY_TIMEOUT_MS)),
        ])
          .catch(() => false)
          .then((ok) => (ok ? send(200, { status: "ready" }) : send(503, { status: "not_ready" })));
      case "/metrics":
        return metrics.registry
          .metrics()
          .then((text) => send(200, text, metrics.registry.contentType))
          .catch(() => send(500, { error: "metrics_failed" }));
      case "/version":
        return send(200, { version: config.GIT_SHA, node: process.version });
      default:
        return send(404, { error: "not_found" });
    }
  });

  // The sweeper: every pod looks for rooms whose phase has ended and advances the ones it gets
  // the lease for, so a round goes on when the pod that started it is gone.
  const inFlight = new Map<string, Promise<void>>();
  let sweeping: NodeJS.Timeout | null = null;
  let pruning: NodeJS.Timeout | null = null;

  async function sweep() {
    if (!redisReady || draining) return;
    let due: string[];
    try {
      due = await store.dueRooms(Date.now() - GRACE_MS, 20);
    } catch (err) {
      metrics.redisErrorsTotal.inc();
      log.warn({ err: String(err) }, "sweep failed");
      return;
    }
    for (const code of due) {
      if (inFlight.has(code)) continue;
      const work = (async () => {
        if (!(await store.claim(code, podId, LEASE_MS))) return;
        try {
          await engine.advance(code);
        } finally {
          await store.release(code, podId);
        }
      })()
        .catch((err: unknown) => {
          metrics.redisErrorsTotal.inc();
          log.error({ err: String(err), room_id: code }, "advancing the room failed");
        })
        .finally(() => inFlight.delete(code));
      inFlight.set(code, work);
    }
  }

  async function closeAll() {
    if (sweeping) clearInterval(sweeping);
    if (pruning) clearInterval(pruning);
    await Promise.allSettled([...inFlight.values()]);
    await new Promise<void>((resolve) => io.close(() => resolve()));
    redisReady = false;
    await Promise.allSettled([redis.close(), sub.close()]);
  }

  return {
    http,
    io,

    async start(port: number) {
      await new Promise<void>((resolve) => http.listen(port, resolve));
      const bound = (http.address() as AddressInfo).port;
      log.info({ port: bound, pod: podId }, "listening");
      await Promise.all([redis.connect(), sub.connect()]);
      io.adapter(createAdapter(redis, sub));
      redisReady = true;
      log.info("connected to redis");
      sweeping = setInterval(() => void sweep(), SWEEP_MS);
      pruning = setInterval(() => void store.pruneActive().catch(() => metrics.redisErrorsTotal.inc()), PRUNE_MS);
      return bound;
    },

    async drain() {
      // 1. Fail readiness and refuse new players; other pods take over advancing rooms.
      draining = true;
      log.info({ drain_delay: config.DRAIN_DELAY_SECONDS }, "draining");
      if (sweeping) clearInterval(sweeping);
      await Promise.allSettled([...inFlight.values()]);
      // 2. Keep serving connected players while the load balancer stops sending new ones.
      await new Promise((r) => setTimeout(r, config.DRAIN_DELAY_SECONDS * 1000));
      // 3. Tell the clients to reconnect; they resume on another pod from Redis.
      io.local.emit("server:draining", {});
      await new Promise((r) => setTimeout(r, 1000));
      // 4. Close what's left.
      await closeAll();
      log.info("stopped");
    },

    close: closeAll,
  };
}
