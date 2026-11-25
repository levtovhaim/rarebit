// All game state lives in Redis, so any pod can serve any room (ADR 0019):
//   rb:room:<code>            the room, as JSON, changed only by compare-and-set
//   rb:room:<code>:t          playerId -> sha256 of the player's resume token
//   rb:room:<code>:a:<round>  playerId -> answer
//   rb:room:<code>:v:<round>  "<answer owner>:<voter>" -> 1 or 0
//   rb:deadlines              sorted set: room code by the epoch ms its phase ends
//   rb:lease:<code>           which pod is advancing the room right now
//   rb:quickplay:open         the code of the public room new quick-play players join
//   rb:rooms:<type>           sorted set: room code by last activity (for the active-rooms gauge)
//   rb:answers                stream of scored answers, for the data pipeline
// Room keys expire after ROOM_TTL_SECONDS without activity.
//
// The keys aren't hash-tagged: this is written for one Redis, not Redis Cluster.
import type { RedisClientType } from "redis";
import type { Room, RoomType } from "./room.js";

/** A node-redis client speaking RESP2, which the Socket.IO Redis adapter's pub/sub is built for. */
export type Redis = RedisClientType<{}, {}, {}, 2, {}>;

const DEADLINES = "rb:deadlines";
const OPEN = "rb:quickplay:open";
const STREAM = "rb:answers";
const STREAM_MAX = 100_000;

const roomKey = (code: string) => `rb:room:${code}`;

// Writes the room only if nobody changed it since it was read, and moves its deadline in the same
// step, so a pod that dies between the two can't leave a room without a timer.
const CAS = `
local cur = redis.call('GET', KEYS[1])
if cur ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'PX', ARGV[3])
if ARGV[5] == '' then redis.call('ZREM', KEYS[2], ARGV[4]) else redis.call('ZADD', KEYS[2], ARGV[5], ARGV[4]) end
return 1`;

const DEL_IF = `
if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0`;

const SET_IF = `
local cur = redis.call('GET', KEYS[1]) or ''
if cur ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'PX', ARGV[3])
return 1`;

/** A change the game refuses: sent back to the client as its code. */
export class GameError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export function createStore(redis: Redis, ttlSeconds: number) {
  const ttlMs = ttlSeconds * 1000;

  return {
    async ping(): Promise<void> {
      await redis.ping();
    },

    async getRoom(code: string): Promise<Room | null> {
      const raw = await redis.get(roomKey(code));
      return raw ? (JSON.parse(raw) as Room) : null;
    },

    /** Creates the room unless the code is taken. */
    async createRoom(room: Room): Promise<boolean> {
      const ok = await redis.set(roomKey(room.code), JSON.stringify(room), {
        condition: "NX",
        expiration: { type: "PX", value: ttlMs },
      });
      if (ok !== "OK") return false;
      await this.touchActive(room.type, room.code);
      return true;
    },

    async deleteRoom(code: string): Promise<void> {
      await redis.del([roomKey(code), `${roomKey(code)}:t`]);
      await redis.zRem(DEADLINES, code);
    },

    /**
     * Read, change, write if unchanged, retry if not. `change` gets the current room and returns
     * the new one, or null to leave it as it is; it may throw GameError. Returns the room as
     * written, or null when the room doesn't exist or `change` left it as it was.
     */
    async updateRoom(code: string, change: (room: Room) => Room | null): Promise<Room | null> {
      for (let attempt = 0; attempt < 20; attempt++) {
        const raw = await redis.get(roomKey(code));
        if (!raw) return null;
        const next = change(JSON.parse(raw) as Room);
        if (!next) return null;
        const written = await redis.eval(CAS, {
          keys: [roomKey(code), DEADLINES],
          arguments: [raw, JSON.stringify(next), String(ttlMs), code, next.deadline === null ? "" : String(next.deadline)],
        });
        if (written === 1) {
          await this.touchActive(next.type, code);
          return next;
        }
        await new Promise((r) => setTimeout(r, Math.random() * 10 * (attempt + 1)));
      }
      throw new GameError("busy");
    },

    async setToken(code: string, playerId: string, hash: string): Promise<void> {
      await redis.hSet(`${roomKey(code)}:t`, playerId, hash);
      await redis.pExpire(`${roomKey(code)}:t`, ttlMs);
    },

    async tokenHash(code: string, playerId: string): Promise<string | null> {
      return (await redis.hGet(`${roomKey(code)}:t`, playerId)) ?? null;
    },

    async setAnswer(code: string, round: number, playerId: string, answer: string): Promise<void> {
      const key = `${roomKey(code)}:a:${round}`;
      await redis.hSet(key, playerId, answer);
      await redis.pExpire(key, ttlMs);
    },

    async answers(code: string, round: number): Promise<Map<string, string>> {
      return new Map(Object.entries(await redis.hGetAll(`${roomKey(code)}:a:${round}`)));
    },

    async setVote(code: string, round: number, ownerId: string, voterId: string, accept: boolean): Promise<void> {
      const key = `${roomKey(code)}:v:${round}`;
      await redis.hSet(key, `${ownerId}:${voterId}`, accept ? "1" : "0");
      await redis.pExpire(key, ttlMs);
    },

    /** Votes per answer owner. */
    async votes(code: string, round: number): Promise<Map<string, boolean[]>> {
      const out = new Map<string, boolean[]>();
      for (const [field, value] of Object.entries(await redis.hGetAll(`${roomKey(code)}:v:${round}`))) {
        const owner = field.split(":")[0]!;
        out.set(owner, [...(out.get(owner) ?? []), value === "1"]);
      }
      return out;
    },

    /** Rooms whose phase ended at or before `before`. */
    async dueRooms(before: number, limit: number): Promise<string[]> {
      return redis.zRangeByScore(DEADLINES, "-inf", before, { LIMIT: { offset: 0, count: limit } });
    },

    /** A lease: only one pod advances a room at a time. Expires by itself if the pod dies. */
    async claim(code: string, owner: string, ms: number): Promise<boolean> {
      const ok = await redis.set(`rb:lease:${code}`, owner, { condition: "NX", expiration: { type: "PX", value: ms } });
      return ok === "OK";
    },

    async release(code: string, owner: string): Promise<void> {
      await redis.eval(DEL_IF, { keys: [`rb:lease:${code}`], arguments: [owner] });
    },

    async openQuickplayRoom(): Promise<string | null> {
      return (await redis.get(OPEN)) ?? null;
    },

    /** Points quick play at `code` if it still points at `expected` ("" for nothing). */
    async claimOpenQuickplay(expected: string, code: string): Promise<boolean> {
      return (await redis.eval(SET_IF, { keys: [OPEN], arguments: [expected, code, String(ttlMs)] })) === 1;
    },

    /** Stops sending quick-play players to `code` (it started or filled up). */
    async closeQuickplay(code: string): Promise<void> {
      await redis.eval(DEL_IF, { keys: [OPEN], arguments: [code] });
    },

    async touchActive(type: RoomType, code: string): Promise<void> {
      await redis.zAdd(`rb:rooms:${type}`, { score: Date.now(), value: code });
    },

    async activeRooms(): Promise<{ private: number; public: number }> {
      const since = Date.now() - ttlMs;
      const [priv, pub] = await Promise.all([
        redis.zCount("rb:rooms:private", since, "+inf"),
        redis.zCount("rb:rooms:public", since, "+inf"),
      ]);
      return { private: priv, public: pub };
    },

    async pruneActive(): Promise<void> {
      const before = Date.now() - ttlMs;
      await Promise.all([
        redis.zRemRangeByScore("rb:rooms:private", "-inf", before),
        redis.zRemRangeByScore("rb:rooms:public", "-inf", before),
      ]);
    },

    /** Scored answers for the data pipeline (ingest reads the stream from Phase 5B). */
    async appendAnswers(events: Array<Record<string, string>>): Promise<void> {
      for (const event of events) {
        await redis.xAdd(STREAM, "*", event, { TRIM: { strategy: "MAXLEN", strategyModifier: "~", threshold: STREAM_MAX } });
      }
    },
  };
}

export type Store = ReturnType<typeof createStore>;
