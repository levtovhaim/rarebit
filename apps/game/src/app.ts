// Builds one game server: HTTP runtime endpoints, Socket.IO on the same port, the Redis clients,
// the sweeper that advances rooms, and the drain on shutdown. main.ts runs one; the integration
// tests run several against the same Redis, as separate "pods".
import { createServer, type IncomingMessage, type Server as HttpServer } from "node:http";
import { hostname } from "node:os";
import { randomBytes } from "node:crypto";
import type { AddressInfo } from "node:net";
import { createAdapter } from "@socket.io/redis-adapter";
import { createClient } from "redis";
import { Server, type Socket } from "socket.io";
import type { Config } from "./config.js";
import { createEngine, GRACE_MS } from "./engine.js";
import type { Logger } from "./log.js";
import { createMetrics } from "./metrics.js";
import { attachSockets } from "./socket.js";
import { createStore, type Redis } from "./store.js";
import { createValidatorClient, type ValidatorClient } from "./validator.js";

const SWEEP_MS = 200;
const LEASE_MS = 15_000; // longer than the slowest evaluation: 8 validator calls with a retry
const PRUNE_MS = 60_000;
const CLOCK_SYNC_MS = 30_000;
const READY_TIMEOUT_MS = 1000;
const IN_FLIGHT_WAIT_MS = 2000;
const MAX_HTTP_BUFFER = 16 * 1024;

export interface GameServer {
  http: HttpServer;
  io: Server;
  /** Listens, then connects to Redis; readiness stays false until Redis answers. */
  start(port: number): Promise<number>;
  /** The shutdown sequence (apps/game/README.md → Shutdown). Resolves when everything is closed. */
  drain(): Promise<void>;
  close(): Promise<void>;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function createGameServer(config: Config, log: Logger, opts: { validator?: ValidatorClient; podId?: string } = {}): GameServer {
  const podId = opts.podId ?? `${hostname()}-${randomBytes(3).toString("hex")}`;
  let draining = false;
  let started = false;
  let closed = false;
  // Redis's clock minus ours: every deadline is on Redis's clock, which every pod shares.
  let clockOffset = 0;
  const now = () => Date.now() + clockOffset;

  // Each connection is named (CLIENT SETNAME), so CLIENT LIST shows which pod and role holds it.
  const redis: Redis = createClient({
    url: config.REDIS_URL,
    name: `rarebit-game:${podId}`,
    // RESP2, as the Socket.IO Redis adapter expects (node-redis 6 defaults to RESP3).
    RESP: 2,
    // Fail commands at once while disconnected instead of queueing them behind a dead socket.
    disableOfflineQueue: true,
    pingInterval: 10_000,
    socket: { connectTimeout: 2000, reconnectStrategy: (retries: number) => Math.min(200 * (retries + 1), 2000) },
  });
  const sub = redis.duplicate({ name: `rarebit-game:${podId}:sub` });
  // The adapter publishes without handling a failure; while Redis reconnects that would be an
  // unhandled rejection, which ends a Node process. Its own client, with publish errors counted.
  const pub = redis.duplicate({ name: `rarebit-game:${podId}:pub` });
  const clients = [redis, sub, pub];
  const redisUp = () => started && !closed && clients.every((c) => c.isReady);

  const http = createServer();
  // Slow or idle clients can't hold HTTP sockets open (WebSockets leave HTTP after the upgrade).
  http.headersTimeout = 5000;
  http.requestTimeout = 10_000;
  const socketPrefix = `${config.SOCKET_PATH.replace(/\/+$/, "")}/`;

  const io = new Server(http, {
    path: config.SOCKET_PATH,
    transports: ["websocket"],
    serveClient: false,
    maxHttpBufferSize: MAX_HTTP_BUFFER,
    pingInterval: 10_000,
    pingTimeout: 5_000,
    allowRequest: (req: IncomingMessage, callback) => {
      // Not while starting, draining or cut off from Redis: the player couldn't play here anyway.
      if (!redisUp() || draining) return callback("not ready", false);
      const origin = req.headers.origin;
      const allowed = config.allowedOrigins === null || (origin !== undefined && config.allowedOrigins.includes(origin));
      callback(allowed ? null : "origin not allowed", allowed);
    },
  });

  const metrics = createMetrics({
    roomsActive: () => (redisUp() ? store.activeRooms() : Promise.resolve({ private: 0, public: 0 })),
    queueLength: async () => {
      if (!redisUp()) return 0;
      const open = await store.openQuickplayRoom();
      const room = open ? await store.getRoom(open) : null;
      return room && (room.phase === "lobby" || room.phase === "countdown") ? room.players.filter((p) => !p.left).length : 0;
    },
    playersConnected: () => io.engine.clientsCount,
    draining: () => draining,
  });
  for (const client of clients) {
    client.on("error", (err: unknown) => {
      metrics.redisErrorsTotal.inc();
      log.warn({ err: String(err) }, "redis error");
    });
  }
  const publish = pub.publish.bind(pub);
  Object.assign(pub, {
    publish: (channel: string, message: string) =>
      publish(channel, message).catch((err: unknown) => {
        metrics.redisErrorsTotal.inc();
        log.warn({ err: String(err) }, "couldn't publish to other pods");
        return 0;
      }),
  });

  const store = createStore(redis, {
    roomTtlSeconds: config.ROOM_TTL_SECONDS,
    lobbyTtlSeconds: config.LOBBY_TTL_SECONDS,
    onError: (err, what) => {
      metrics.redisErrorsTotal.inc();
      log.warn({ err: String(err) }, `couldn't ${what}`);
    },
  });

  const validator = opts.validator ?? createValidatorClient(config.VALIDATOR_URL, log, metrics);
  const engine = createEngine({
    store,
    validator,
    emit: (room, event, payload) => io.to(room).emit(event, payload),
    config,
    metrics,
    log,
    now,
  });

  // At most MAX_CONNECTIONS_PER_IP sockets per client address on this pod.
  const perIp = new Map<string, number>();
  function clientIp(socket: Socket): string {
    const hops = config.TRUSTED_PROXY_HOPS;
    const forwarded = socket.handshake.headers["x-forwarded-for"];
    if (hops > 0 && typeof forwarded === "string") {
      // Each trusted proxy appends the address it saw; the client's is `hops` entries from the end.
      const chain = forwarded.split(",").map((s) => s.trim()).filter(Boolean);
      const ip = chain[chain.length - hops];
      if (ip) return ip;
    }
    return socket.handshake.address;
  }
  io.use((socket, next) => {
    const ip = clientIp(socket);
    const count = perIp.get(ip) ?? 0;
    if (count >= config.MAX_CONNECTIONS_PER_IP) return next(new Error("too_many_connections"));
    perIp.set(ip, count + 1);
    socket.once("disconnect", () => {
      const left = (perIp.get(ip) ?? 1) - 1;
      if (left <= 0) perIp.delete(ip);
      else perIp.set(ip, left);
    });
    next();
  });
  attachSockets(io, engine, { metrics, log, draining: () => draining, now });

  async function ready(): Promise<boolean> {
    if (draining || !redisUp()) return false;
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        store.readyWrite(podId).then(() => true),
        new Promise<boolean>((resolve) => {
          timer = setTimeout(() => resolve(false), READY_TIMEOUT_MS);
        }),
      ]);
    } catch {
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  // Runtime endpoints. Socket.IO answers its own path before this handler sees it.
  http.on("request", (req, res) => {
    if (req.url?.startsWith(socketPrefix)) return;
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
        return ready().then((ok) => (ok ? send(200, { status: "ready" }) : send(503, { status: "not_ready" })));
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

  async function syncClock(): Promise<void> {
    const before = Date.now();
    const redisNow = await store.time();
    const after = Date.now();
    clockOffset = redisNow - Math.round((before + after) / 2);
  }

  // The sweeper: every pod looks for rooms whose phase has ended and advances the ones it gets
  // the lease for, so a round goes on when the pod that started it is gone (ADR 0021).
  const inFlight = new Map<string, Promise<void>>();
  const timers = new Set<NodeJS.Timeout>();
  let sweeping = false;

  /** Runs `work` every `ms` after the previous run finished, so a slow Redis can't stack runs up. */
  function every(ms: number, work: () => Promise<void>) {
    const run = () => {
      const t = setTimeout(async () => {
        timers.delete(t);
        await work().catch(() => {});
        if (!closed) run();
      }, ms);
      timers.add(t);
    };
    run();
  }

  async function sweep() {
    // Only the command connection is needed: with pub/sub down, this pod's own players still get
    // the events, and the others catch up with room:sync. A stalled room helps nobody.
    if (!started || closed || !redis.isReady || draining || sweeping) return;
    sweeping = true;
    try {
      const t = now();
      let due: string[];
      try {
        due = await store.dueRooms(t - GRACE_MS, 20);
      } catch (err) {
        metrics.redisErrorsTotal.inc();
        log.warn({ err: String(err) }, "sweep failed");
        return;
      }
      for (const code of due) {
        if (inFlight.has(code)) continue;
        const work = (async () => {
          if (!(await store.claim(code, podId, LEASE_MS, t))) return;
          try {
            await engine.advance(code);
          } finally {
            // The entry back at the room's real deadline (or gone with the room), then the lease.
            await store.settle(code);
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
    } finally {
      sweeping = false;
    }
  }

  async function closeAll() {
    if (closed) return;
    closed = true;
    for (const t of timers) clearTimeout(t);
    timers.clear();
    await Promise.race([Promise.allSettled([...inFlight.values()]), sleep(IN_FLIGHT_WAIT_MS)]);
    await new Promise<void>((resolve) => io.close(() => resolve()));
    await Promise.allSettled(clients.map((c) => c.close()));
  }

  return {
    http,
    io,

    async start(port: number) {
      await new Promise<void>((resolve) => http.listen(port, resolve));
      const bound = (http.address() as AddressInfo).port;
      log.info({ port: bound, pod: podId }, "listening");
      await Promise.all(clients.map((c) => c.connect()));
      await syncClock();
      io.adapter(createAdapter(pub, sub));
      started = true;
      log.info({ clock_offset_ms: clockOffset }, "connected to redis");
      every(SWEEP_MS, sweep);
      every(CLOCK_SYNC_MS, () =>
        syncClock().catch((err: unknown) => {
          metrics.redisErrorsTotal.inc();
          log.warn({ err: String(err) }, "clock sync failed");
        }),
      );
      every(PRUNE_MS, () => store.prune().catch(() => void metrics.redisErrorsTotal.inc()));
      return bound;
    },

    async drain() {
      // 1. Fail readiness and refuse new players; the sweeper stops, other pods take over rooms.
      draining = true;
      log.info({ drain_delay: config.DRAIN_DELAY_SECONDS }, "draining");
      // 2. Keep serving connected players while the load balancer stops sending new ones. Rooms
      //    this pod is advancing finish meanwhile (bounded: their leases let other pods take over).
      await Promise.all([
        sleep(config.DRAIN_DELAY_SECONDS * 1000),
        Promise.race([Promise.allSettled([...inFlight.values()]), sleep(IN_FLIGHT_WAIT_MS)]),
      ]);
      // 3. Tell the clients to reconnect; they resume on another pod from Redis.
      io.local.emit("server:draining", {});
      await sleep(1000);
      // 4. Close what's left.
      await closeAll();
      log.info("stopped");
    },

    close: closeAll,
  };
}
