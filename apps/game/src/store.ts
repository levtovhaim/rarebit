// All game state lives in Redis, so any pod can serve any room (ADRs 0019, 0021):
//   rb:room:<code>            the room, as JSON, changed only by compare-and-set
//   rb:room:<code>:t          playerId -> sha256 of the player's resume token
//   rb:room:<code>:a:<round>  playerId -> answer
//   rb:room:<code>:v:<round>  "<answer owner>:<voter>" -> 1 or 0
//   rb:deadlines              sorted set: room code by the epoch ms its phase ends
//   rb:lease:<code>           which pod is advancing the room right now
//   rb:quickplay:open         the code of the public room new quick-play players join
//   rb:rooms:<type>           sorted set: room code by last activity (for the active-rooms gauge)
//   rb:categories             the last playable-category list any pod fetched
//   rb:ready:<pod>            written by each readiness check
//   rb:answers                stream of scored answers, for the data pipeline
// A room's keys expire after LOBBY_TTL_SECONDS until its game starts (and once it ends), and
// after ROOM_TTL_SECONDS during the game, counted from the last change. The sorted sets are
// pruned instead.
//
// The keys aren't hash-tagged: this is written for one Redis, not Redis Cluster.
import type { RedisClientType } from "redis";
import type { Room, RoomType } from "./room.js";
import type { CategoryInfo } from "./rules.js";

/** A node-redis client speaking RESP2, which the Socket.IO Redis adapter's pub/sub is built for. */
export type Redis = RedisClientType<{}, {}, {}, 2, {}>;

const DEADLINES = "rb:deadlines";
const OPEN = "rb:quickplay:open";
const STREAM = "rb:answers";
const STREAM_MAX = 100_000;
const CATEGORIES = "rb:categories";
const CATEGORIES_TTL_MS = 3_600_000;

const roomKey = (code: string) => `rb:room:${code}`;
const tokensKey = (code: string) => `${roomKey(code)}:t`;

// Creates the room and its first player's token together, so no player exists without one.
const CREATE = `
if not redis.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then return 0 end
redis.call('HSET', KEYS[2], ARGV[3], ARGV[4])
redis.call('PEXPIRE', KEYS[2], ARGV[2])
return 1`;

// Writes the room only if nobody changed it since it was read, moves its deadline in the same
// step (so a pod that dies between the two can't leave a room without a timer), and keeps the
// token hash alive as long as the room.
const CAS = `
local cur = redis.call('GET', KEYS[1])
if cur ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'PX', ARGV[3])
redis.call('PEXPIRE', KEYS[3], ARGV[3])
if ARGV[5] == '' then redis.call('ZREM', KEYS[2], ARGV[4]) else redis.call('ZADD', KEYS[2], ARGV[5], ARGV[4]) end
return 1`;

// A token for a room that exists, expiring with it: a guessed room code leaves nothing behind.
const SET_TOKEN = `
local ttl = redis.call('PTTL', KEYS[1])
if ttl <= 0 then return 0 end
redis.call('HSET', KEYS[2], ARGV[1], ARGV[2])
redis.call('PEXPIRE', KEYS[2], ttl)
return 1`;

const DELETE = `
redis.call('DEL', KEYS[1], KEYS[2])
redis.call('ZREM', KEYS[3], ARGV[1])
return 1`;

const NOW_MS = `
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)`;

// Accepts an answer only while the round runs, by Redis's clock, in the same step as the write:
// an acknowledged answer is always in the hash the evaluation reads.
const ANSWER = `
local raw = redis.call('GET', KEYS[1])
if not raw then return 'not_found' end
local r = cjson.decode(raw)
if r.phase ~= 'round' or r.round ~= tonumber(ARGV[2]) then return 'not_accepting' end
${NOW_MS}
if r.deadline == cjson.null or now > r.deadline then return 'too_late' end
local playing = false
for _, p in ipairs(r.players) do
  if p.id == ARGV[1] then playing = (not p.eliminated) and (not p.left) end
end
if not playing then return 'not_playing' end
redis.call('HSET', KEYS[2], ARGV[1], ARGV[3])
redis.call('PEXPIRE', KEYS[2], ARGV[4])
return 'ok'`;

// The same for a vote: the voting phase, by Redis's clock; a voter still in the room, not the
// answer's author; an unknown answer to vote on.
const VOTE = `
local raw = redis.call('GET', KEYS[1])
if not raw then return 'not_found' end
local r = cjson.decode(raw)
if r.phase ~= 'voting' or r.round ~= tonumber(ARGV[2]) then return 'not_voting' end
${NOW_MS}
if r.deadline == cjson.null or now > r.deadline then return 'too_late' end
if ARGV[1] == ARGV[3] then return 'not_allowed' end
local voter = false
for _, p in ipairs(r.players) do
  if p.id == ARGV[1] then voter = not p.left end
end
if not voter then return 'not_allowed' end
local open = false
if r.pending ~= cjson.null then
  for _, a in ipairs(r.pending) do
    if a.playerId == ARGV[3] and a.verdict == 'unknown' then open = true end
  end
end
if not open then return 'not_found' end
redis.call('HSET', KEYS[2], ARGV[3] .. ':' .. ARGV[1], ARGV[4])
redis.call('PEXPIRE', KEYS[2], ARGV[5])
return 'ok'`;

// A lease: only one pod advances a room at a time. The claim also pushes the room's deadline
// back by the lease, so rooms being advanced (or failing to) stop filling the front of the queue;
// SETTLE puts the real deadline back afterwards. Both expire by themselves if the pod dies.
const CLAIM = `
if not redis.call('SET', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then return 0 end
redis.call('ZADD', KEYS[2], 'XX', tonumber(ARGV[4]) + tonumber(ARGV[2]), ARGV[3])
return 1`;

// Makes a room's entry in the deadline set match the room again, or removes it when the room is gone.
const SETTLE = `
local raw = redis.call('GET', KEYS[1])
if not raw then redis.call('ZREM', KEYS[2], ARGV[1]) return 0 end
local d = cjson.decode(raw).deadline
if d == nil or d == cjson.null then redis.call('ZREM', KEYS[2], ARGV[1]) else redis.call('ZADD', KEYS[2], d, ARGV[1]) end
return 1`;

const DEL_IF = `
if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0`;

const SET_IF = `
local cur = redis.call('GET', KEYS[1]) or ''
if cur ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'PX', ARGV[3])
return 1`;

const EXPIRE_IF = `
if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('PEXPIRE', KEYS[1], ARGV[2]) end
return 0`;

/** A change the game refuses: sent back to the client as its code. */
export class GameError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export interface StoreOptions {
  roomTtlSeconds: number;
  lobbyTtlSeconds: number;
  /** For best-effort writes (bookkeeping) that fail: counted and logged, never thrown. */
  onError: (err: unknown, what: string) => void;
}

export function createStore(redis: Redis, opts: StoreOptions) {
  const roomMs = opts.roomTtlSeconds * 1000;
  const lobbyMs = opts.lobbyTtlSeconds * 1000;
  /** Lobbies and finished games expire sooner: they hold nothing worth keeping. */
  const ttlFor = (room: Room) => (room.round === 0 || room.phase === "ended" ? lobbyMs : roomMs);

  const touchActive = (type: RoomType, code: string) =>
    redis.zAdd(`rb:rooms:${type}`, { score: Date.now(), value: code }).catch((err) => opts.onError(err, "touch active rooms"));

  return {
    /** Readiness: a write, which also fails on a read-only replica after a failover. */
    async readyWrite(pod: string): Promise<void> {
      await redis.set(`rb:ready:${pod}`, "1", { expiration: { type: "PX", value: 5000 } });
    },

    /** Redis's clock in epoch milliseconds. */
    async time(): Promise<number> {
      const [seconds, micros] = await redis.time();
      return Number(seconds) * 1000 + Math.floor(Number(micros) / 1000);
    },

    async getRoom(code: string): Promise<Room | null> {
      const raw = await redis.get(roomKey(code));
      return raw ? (JSON.parse(raw) as Room) : null;
    },

    /** Creates the room with its first player's token, unless the code is taken. */
    async createRoom(room: Room, playerId: string, tokenHash: string): Promise<boolean> {
      const created = await redis.eval(CREATE, {
        keys: [roomKey(room.code), tokensKey(room.code)],
        arguments: [JSON.stringify(room), String(ttlFor(room)), playerId, tokenHash],
      });
      if (created !== 1) return false;
      void touchActive(room.type, room.code);
      return true;
    },

    async deleteRoom(code: string): Promise<void> {
      await redis.eval(DELETE, { keys: [roomKey(code), tokensKey(code), DEADLINES], arguments: [code] });
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
          keys: [roomKey(code), DEADLINES, tokensKey(code)],
          arguments: [raw, JSON.stringify(next), String(ttlFor(next)), code, next.deadline === null ? "" : String(next.deadline)],
        });
        if (written === 1) {
          void touchActive(next.type, code);
          return next;
        }
        await new Promise((r) => setTimeout(r, Math.random() * 10 * (attempt + 1)));
      }
      throw new GameError("busy");
    },

    /**
     * Stores a token's hash, if the room exists. Set before the player is added to the room, so no
     * player lacks one.
     */
    async setToken(code: string, playerId: string, hash: string): Promise<boolean> {
      return (await redis.eval(SET_TOKEN, { keys: [roomKey(code), tokensKey(code)], arguments: [playerId, hash] })) === 1;
    },

    async tokenHash(code: string, playerId: string): Promise<string | null> {
      return (await redis.hGet(tokensKey(code), playerId)) ?? null;
    },

    /** "ok", or the GameError code the answer is refused with. */
    async acceptAnswer(code: string, round: number, playerId: string, answer: string): Promise<string> {
      return String(
        await redis.eval(ANSWER, {
          keys: [roomKey(code), `${roomKey(code)}:a:${round}`],
          arguments: [playerId, String(round), answer, String(roomMs)],
        }),
      );
    },

    async answers(code: string, round: number): Promise<Map<string, string>> {
      return new Map(Object.entries(await redis.hGetAll(`${roomKey(code)}:a:${round}`)));
    },

    /** "ok", or the GameError code the vote is refused with. */
    async acceptVote(code: string, round: number, voterId: string, ownerId: string, accept: boolean): Promise<string> {
      return String(
        await redis.eval(VOTE, {
          keys: [roomKey(code), `${roomKey(code)}:v:${round}`],
          arguments: [voterId, String(round), ownerId, accept ? "1" : "0", String(roomMs)],
        }),
      );
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

    /** Rooms whose phase ended at or before `before`, oldest first. */
    async dueRooms(before: number, limit: number): Promise<string[]> {
      return redis.zRangeByScore(DEADLINES, "-inf", before, { LIMIT: { offset: 0, count: limit } });
    },

    async claim(code: string, owner: string, leaseMs: number, now: number): Promise<boolean> {
      const ok = await redis.eval(CLAIM, {
        keys: [`rb:lease:${code}`, DEADLINES],
        arguments: [owner, String(leaseMs), code, String(now)],
      });
      return ok === 1;
    },

    async settle(code: string): Promise<void> {
      await redis.eval(SETTLE, { keys: [roomKey(code), DEADLINES], arguments: [code] });
    },

    async release(code: string, owner: string): Promise<void> {
      await redis.eval(DEL_IF, { keys: [`rb:lease:${code}`], arguments: [owner] });
    },

    async openQuickplayRoom(): Promise<string | null> {
      return (await redis.get(OPEN)) ?? null;
    },

    /** Points quick play at `code` if it still points at `expected` ("" for nothing). */
    async claimOpenQuickplay(expected: string, code: string): Promise<boolean> {
      return (await redis.eval(SET_IF, { keys: [OPEN], arguments: [expected, code, String(lobbyMs)] })) === 1;
    },

    /** Keeps the pointer alive while players keep joining `code`. */
    async touchOpenQuickplay(code: string): Promise<void> {
      await redis.eval(EXPIRE_IF, { keys: [OPEN], arguments: [code, String(lobbyMs)] });
    },

    /** Stops sending quick-play players to `code` (it started, filled up or emptied). */
    async closeQuickplay(code: string): Promise<void> {
      await redis.eval(DEL_IF, { keys: [OPEN], arguments: [code] });
    },

    async activeRooms(): Promise<{ private: number; public: number }> {
      const since = Date.now() - roomMs;
      const [priv, pub] = await Promise.all([
        redis.zCount("rb:rooms:private", since, "+inf"),
        redis.zCount("rb:rooms:public", since, "+inf"),
      ]);
      return { private: priv, public: pub };
    },

    /** Drops activity entries and deadlines older than any room can live. */
    async prune(): Promise<void> {
      const before = Date.now() - roomMs;
      await Promise.all([
        redis.zRemRangeByScore("rb:rooms:private", "-inf", before),
        redis.zRemRangeByScore("rb:rooms:public", "-inf", before),
        redis.zRemRangeByScore(DEADLINES, "-inf", before),
      ]);
    },

    async setSharedCategories(list: CategoryInfo[]): Promise<void> {
      await redis.set(CATEGORIES, JSON.stringify(list), { expiration: { type: "PX", value: CATEGORIES_TTL_MS } });
    },

    async sharedCategories(): Promise<CategoryInfo[] | null> {
      const raw = await redis.get(CATEGORIES);
      return raw ? (JSON.parse(raw) as CategoryInfo[]) : null;
    },

    /**
     * Scored answers for the data pipeline. Written after the round's result, not with it: a
     * failed append loses those entries. Room, round and player identify an entry.
     */
    async appendAnswers(events: Array<Record<string, string>>): Promise<void> {
      for (const event of events) {
        await redis.xAdd(STREAM, "*", event, { TRIM: { strategy: "MAXLEN", strategyModifier: "~", threshold: STREAM_MAX } });
      }
    },
  };
}

export type Store = ReturnType<typeof createStore>;
