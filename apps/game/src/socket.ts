// Client events (ADR 0020). Every event carries an acknowledgement callback and gets
// { ok: true, ... } or { ok: false, error: "<code>" } back. Payloads are checked with zod, and
// each socket has a token-bucket rate limit.
import type { Server, Socket } from "socket.io";
import { z } from "zod";
import type { Engine, Joined } from "./engine.js";
import { ROOM_CODE } from "./ids.js";
import type { Logger } from "./log.js";
import type { Metrics } from "./metrics.js";
import { snapshot } from "./room.js";
import { GameError } from "./store.js";

const nickname = z.string().max(64);
const roomCode = z
  .string()
  .max(16)
  .transform((s) => s.trim().toUpperCase())
  .pipe(z.string().regex(ROOM_CODE));
const round = z.number().int().min(1).max(100);
const id = z.uuid();

const schemas = {
  "room:create": z.object({ nickname }),
  "room:join": z.object({ roomCode, nickname }),
  "quickplay:join": z.object({ nickname }),
  "room:resume": z.object({ roomCode, playerId: id, token: z.string().min(16).max(64) }),
  "game:start": z.object({}),
  "answer:submit": z.object({ round, answer: z.string().max(256) }),
  "vote:cast": z.object({ round, playerId: id, accept: z.boolean() }),
  "room:leave": z.object({}),
  "room:sync": z.object({}),
} as const;

type EventName = keyof typeof schemas;
type Ack = (reply: Record<string, unknown>) => void;

interface SocketData {
  roomCode?: string;
  playerId?: string;
}

/** Joins and resumes refused for a wrong room code or token before the socket is cut off. */
const MAX_FAILED_JOINS = 5;

/** 10 events in a burst, then 5 a second. */
function bucket(capacity = 10, perSecond = 5) {
  let tokens = capacity;
  let at = Date.now();
  return () => {
    const t = Date.now();
    tokens = Math.min(capacity, tokens + ((t - at) / 1000) * perSecond);
    at = t;
    if (tokens < 1) return false;
    tokens -= 1;
    return true;
  };
}

export function attachSockets(
  io: Server,
  engine: Engine,
  deps: { metrics: Metrics; log: Logger; draining: () => boolean; now?: () => number },
): void {
  const now = deps.now ?? Date.now;

  io.on("connection", (socket: Socket) => {
    const data = socket.data as SocketData;
    const take = bucket();
    let failedJoins = 0;

    function bound(): { code: string; playerId: string } {
      if (!data.roomCode || !data.playerId) throw new GameError("not_in_room");
      return { code: data.roomCode, playerId: data.playerId };
    }

    function notDraining() {
      // Readiness is already failing; anyone still arriving should reconnect elsewhere.
      if (deps.draining()) throw new GameError("draining");
    }

    /** Counts guesses at room codes and tokens; the socket is closed after MAX_FAILED_JOINS. */
    async function guarded<T>(work: () => Promise<T>): Promise<T> {
      try {
        return await work();
      } catch (err) {
        if (err instanceof GameError && (err.code === "not_found" || err.code === "bad_token") && ++failedJoins >= MAX_FAILED_JOINS) {
          deps.log.info({ failed_joins: failedJoins }, "too many failed joins; closing the connection");
          setTimeout(() => socket.disconnect(true), 0); // after the reply goes out
        }
        throw err;
      }
    }

    /**
     * One seat per socket: binding to a new seat leaves the one the socket held before, after the
     * new one succeeded (a mistyped room code doesn't cost the old seat).
     */
    async function bind(code: string, playerId: string) {
      const prev = data.roomCode && data.playerId ? { code: data.roomCode, playerId: data.playerId } : null;
      data.roomCode = code;
      data.playerId = playerId;
      await socket.join(code);
      if (!prev || (prev.code === code && prev.playerId === playerId)) return;
      if (prev.code !== code) await socket.leave(prev.code);
      await engine.leave(prev.code, prev.playerId).catch((err: unknown) => {
        deps.metrics.redisErrorsTotal.inc();
        deps.log.warn({ err: String(err), room_id: prev.code }, "couldn't leave the previous seat");
      });
    }

    async function seat(joined: Joined) {
      await bind(joined.room.code, joined.player.id);
      return { roomCode: joined.room.code, playerId: joined.player.id, token: joined.token, state: snapshot(joined.room, now()) };
    }

    function on<E extends EventName>(event: E, handler: (payload: z.output<(typeof schemas)[E]>) => Promise<Record<string, unknown> | void>) {
      socket.on(event as string, async (payload: unknown, ack: unknown) => {
        if (typeof ack !== "function") return;
        const reply = ack as Ack;
        if (!take()) {
          deps.metrics.rateLimitedTotal.inc();
          return reply({ ok: false, error: "rate_limited" });
        }
        const parsed = schemas[event].safeParse(payload ?? {});
        if (!parsed.success) return reply({ ok: false, error: "bad_request" });
        try {
          reply({ ok: true, ...((await handler(parsed.data as z.output<(typeof schemas)[E]>)) ?? {}) });
        } catch (err) {
          if (err instanceof GameError) return reply({ ok: false, error: err.code });
          deps.metrics.redisErrorsTotal.inc();
          deps.log.error({ err: String(err), event, room_id: data.roomCode }, "event failed");
          reply({ ok: false, error: "unavailable" });
        }
      });
    }

    on("room:create", async ({ nickname: nick }) => {
      notDraining();
      return seat(await engine.createPrivate(nick, socket.id));
    });

    on("room:join", async ({ roomCode: code, nickname: nick }) => {
      notDraining();
      return seat(await guarded(() => engine.joinPrivate(code, nick, socket.id)));
    });

    on("quickplay:join", async ({ nickname: nick }) => {
      notDraining();
      return seat(await engine.joinQuickplay(nick, socket.id));
    });

    on("room:resume", async ({ roomCode: code, playerId, token }) => {
      notDraining();
      const resumed = await guarded(() => engine.resume(code, playerId, token, socket.id));
      await bind(code, playerId);
      // The seat's older connection (another tab, or a socket the pod hasn't noticed is dead) is
      // closed, on whichever pod holds it.
      if (resumed.previousConn) io.in(resumed.previousConn).disconnectSockets(true);
      return { token: resumed.token, state: snapshot(resumed.room, now()) };
    });

    on("game:start", async () => {
      const { code, playerId } = bound();
      await engine.start(code, playerId);
    });

    on("answer:submit", async ({ round: r, answer }) => {
      const end = deps.metrics.answerAckSeconds.startTimer();
      try {
        const { code, playerId } = bound();
        await engine.answer(code, playerId, r, answer);
      } finally {
        end();
      }
    });

    on("vote:cast", async ({ round: r, playerId: owner, accept }) => {
      const { code, playerId } = bound();
      await engine.vote(code, playerId, r, owner, accept);
    });

    on("room:leave", async () => {
      const { code, playerId } = bound();
      await engine.leave(code, playerId);
      await socket.leave(code);
      delete data.roomCode;
      delete data.playerId;
    });

    on("room:sync", async () => {
      const { code } = bound();
      return { state: snapshot(await engine.sync(code), now()) };
    });

    socket.on("disconnect", (reason: string) => {
      deps.metrics.wsDisconnectsTotal.inc({ reason });
      if (data.roomCode && data.playerId) {
        engine.disconnected(data.roomCode, data.playerId, socket.id).catch((err: unknown) => {
          deps.metrics.redisErrorsTotal.inc();
          deps.log.warn({ err: String(err), room_id: data.roomCode }, "couldn't mark a player disconnected");
        });
      }
    });
  });
}
