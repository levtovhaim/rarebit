// The game itself: joining rooms, and the phase transitions the sweeper drives. Every change goes
// through store.updateRoom, and every transition first checks that the room is still in the state
// it read, so two pods advancing the same room can't both apply it (ADR 0019).
import { timingSafeEqual } from "node:crypto";
import type { Config } from "./config.js";
import { isBlocked } from "./filter/filter.js";
import { filterCompact } from "./filter/normalize.js";
import { playerId, roomCode, token, tokenHash } from "./ids.js";
import type { Logger } from "./log.js";
import type { Metrics } from "./metrics.js";
import { snapshot, type PendingAnswer, type Room, type RoomType, type RoundResult } from "./room.js";
import {
  MAX_PLAYERS,
  MIN_PRIVATE_PLAYERS,
  applyScores,
  cleanAnswer,
  cleanNickname,
  isActive,
  isGameOver,
  pickRound,
  scoreRound,
  standings,
  voteAccepted,
  winners,
  type Player,
  type Scored,
} from "./rules.js";
import { GameError, type Store } from "./store.js";
import type { ValidatorClient } from "./validator.js";

/** Answers can still be landing in Redis when a round's deadline passes: wait this long. */
export const GRACE_MS = 250;
/** How soon to try again when the categories can't be fetched for a new round. */
const RETRY_MS = 2000;

export type Emit = (room: string, event: string, payload: unknown) => void;

export interface EngineDeps {
  store: Store;
  validator: ValidatorClient;
  emit: Emit;
  config: Config;
  metrics: Metrics;
  log: Logger;
  now?: () => number;
  rng?: () => number;
}

export interface Joined {
  room: Room;
  player: Player;
  token: string;
}

export function createEngine(d: EngineDeps) {
  const now = d.now ?? Date.now;
  const rng = d.rng ?? Math.random;
  const c = d.config;

  const broadcast = (room: Room) => d.emit(room.code, "room:state", snapshot(room, now()));
  const same = (r: Room, seen: Room) => r.phase === seen.phase && r.round === seen.round && r.deadline === seen.deadline;
  const roomLog = (room: Room) => d.log.child({ room_id: room.code, round: room.round });

  function nickname(raw: string): string {
    const nick = cleanNickname(raw);
    if (!nick) throw new GameError("bad_nickname");
    if (isBlocked(nick, "nickname")) {
      d.metrics.filterBlockedTotal.inc({ field: "nickname" });
      throw new GameError("nickname_blocked");
    }
    return nick;
  }

  function newPlayer(nick: string, conn: string): Player {
    return { id: playerId(), nickname: nick, score: 0, strikes: 0, eliminated: false, left: false, connected: true, joinedAt: now(), conn };
  }

  function newRoom(code: string, type: RoomType, host: Player): Room {
    return {
      code,
      type,
      phase: "lobby",
      hostId: type === "private" ? host.id : null,
      players: [host],
      maxRounds: c.MAX_ROUNDS,
      createdAt: now(),
      startedAt: null,
      round: 0,
      letter: null,
      category: null,
      deadline: null,
      used: [],
      pending: null,
      lastResults: null,
      winners: null,
    };
  }

  /** Adds a player; in a public room a taken nickname gets a number instead of an error. */
  function addPlayer(room: Room, player: Player): Room {
    const present = room.players.filter((p) => !p.left);
    if (present.length >= MAX_PLAYERS) throw new GameError("room_full");
    const taken = new Set(present.map((p) => p.nickname.toLocaleLowerCase("he")));
    let nick = player.nickname;
    if (taken.has(nick.toLocaleLowerCase("he"))) {
      if (room.type === "private") throw new GameError("nickname_taken");
      const free = [2, 3, 4, 5, 6, 7, 8, 9].map((n) => `${nick} ${n}`).find((n) => !taken.has(n.toLocaleLowerCase("he")));
      if (!free) throw new GameError("nickname_taken");
      nick = free;
    }
    return { ...room, players: [...room.players, { ...player, nickname: nick }] };
  }

  async function withToken(room: Room, player: Player): Promise<Joined> {
    const t = token();
    await d.store.setToken(room.code, player.id, tokenHash(t));
    return { room, player: room.players.find((p) => p.id === player.id) ?? player, token: t };
  }

  const engine = {
    async createPrivate(rawNickname: string, conn: string): Promise<Joined> {
      const player = newPlayer(nickname(rawNickname), conn);
      for (let attempt = 0; attempt < 5; attempt++) {
        const room = newRoom(roomCode(), "private", player);
        if (await d.store.createRoom(room)) return withToken(room, player);
      }
      throw new GameError("busy");
    },

    async joinPrivate(code: string, rawNickname: string, conn: string): Promise<Joined> {
      const player = newPlayer(nickname(rawNickname), conn);
      const room = await d.store.updateRoom(code, (r) => {
        if (r.type !== "private") throw new GameError("not_found");
        if (r.phase !== "lobby") throw new GameError("already_started");
        return addPlayer(r, player);
      });
      if (!room) throw new GameError("not_found");
      broadcast(room);
      return withToken(room, player);
    },

    /** Joins the open public room, or opens a new one. It starts at 8 players, or after a countdown from QUICKPLAY_MIN_PLAYERS. */
    async joinQuickplay(rawNickname: string, conn: string): Promise<Joined> {
      const nick = nickname(rawNickname);
      for (let attempt = 0; attempt < 8; attempt++) {
        const open = await d.store.openQuickplayRoom();
        const player = newPlayer(nick, conn);
        if (open) {
          let room: Room | null = null;
          try {
            room = await d.store.updateRoom(open, (r) => {
              if (r.type !== "public" || (r.phase !== "lobby" && r.phase !== "countdown")) throw new GameError("closed");
              const next = addPlayer(r, player);
              const count = next.players.filter((p) => !p.left).length;
              if (count >= MAX_PLAYERS) return { ...next, phase: "countdown", deadline: now() };
              if (next.phase === "lobby" && count >= c.QUICKPLAY_MIN_PLAYERS) {
                return { ...next, phase: "countdown", deadline: now() + c.QUICKPLAY_COUNTDOWN_SECONDS * 1000 };
              }
              return next;
            });
          } catch (err) {
            if (!(err instanceof GameError) || (err.code !== "closed" && err.code !== "room_full")) throw err;
          }
          if (room) {
            if (room.players.filter((p) => !p.left).length >= MAX_PLAYERS) await d.store.closeQuickplay(open);
            broadcast(room);
            return withToken(room, player);
          }
        }
        const fresh = newRoom(roomCode(), "public", player);
        if (!(await d.store.createRoom(fresh))) continue;
        if (!(await d.store.claimOpenQuickplay(open ?? "", fresh.code))) {
          await d.store.deleteRoom(fresh.code); // another pod opened a room first: join that one
          continue;
        }
        return withToken(fresh, player);
      }
      throw new GameError("busy");
    },

    /** Reconnects a player to their room (after a dropped connection or a pod going away). */
    async resume(code: string, id: string, rawToken: string, conn: string): Promise<Room> {
      const stored = await d.store.tokenHash(code, id);
      const given = tokenHash(rawToken);
      if (!stored || stored.length !== given.length || !timingSafeEqual(Buffer.from(stored), Buffer.from(given))) {
        throw new GameError("bad_token");
      }
      const room = await d.store.updateRoom(code, (r) =>
        r.players.some((p) => p.id === id)
          ? { ...r, players: r.players.map((p) => (p.id === id ? { ...p, connected: true, conn } : p)) }
          : null,
      );
      if (!room) throw new GameError("not_found");
      broadcast(room);
      return room;
    },

    async disconnected(code: string, id: string, conn: string): Promise<void> {
      const room = await d.store.updateRoom(code, (r) =>
        r.players.some((p) => p.id === id && p.conn === conn)
          ? { ...r, players: r.players.map((p) => (p.id === id ? { ...p, connected: false, conn: null } : p)) }
          : null, // a newer connection already took over
      );
      if (room) broadcast(room);
    },

    async start(code: string, id: string): Promise<void> {
      const room = await d.store.updateRoom(code, (r) => {
        if (r.type !== "private") throw new GameError("not_allowed");
        if (r.hostId !== id) throw new GameError("not_host");
        if (r.phase !== "lobby") throw new GameError("already_started");
        if (r.players.filter((p) => !p.left).length < MIN_PRIVATE_PLAYERS) throw new GameError("not_enough_players");
        return { ...r, phase: "countdown", deadline: now() }; // the sweeper starts round 1 right away
      });
      if (!room) throw new GameError("not_found");
      broadcast(room);
    },

    async answer(code: string, id: string, round: number, raw: string): Promise<void> {
      const room = await d.store.getRoom(code);
      if (!room) throw new GameError("not_found");
      if (room.phase !== "round" || room.round !== round) throw new GameError("not_accepting");
      if (room.deadline === null || now() > room.deadline) throw new GameError("too_late");
      const p = room.players.find((x) => x.id === id);
      if (!p || !isActive(p)) throw new GameError("not_playing");
      await d.store.setAnswer(code, round, id, cleanAnswer(raw));
    },

    async vote(code: string, voterId: string, round: number, ownerId: string, accept: boolean): Promise<void> {
      const room = await d.store.getRoom(code);
      if (!room) throw new GameError("not_found");
      if (room.phase !== "voting" || room.round !== round) throw new GameError("not_voting");
      const voter = room.players.find((p) => p.id === voterId);
      if (!voter || voter.left || voterId === ownerId) throw new GameError("not_allowed");
      if (!room.pending?.some((a) => a.playerId === ownerId && a.verdict === "unknown")) throw new GameError("not_found");
      await d.store.setVote(code, round, ownerId, voterId, accept);
    },

    async leave(code: string, id: string): Promise<void> {
      let empty = false;
      const room = await d.store.updateRoom(code, (r) => {
        const p = r.players.find((x) => x.id === id);
        if (!p || p.left) return null;
        let next: Room;
        if (r.round === 0) {
          // Not started: the player is simply gone, and the host role moves on.
          const players = r.players.filter((x) => x.id !== id);
          next = { ...r, players, hostId: r.hostId === id ? (players[0]?.id ?? null) : r.hostId };
          if (next.type === "public" && next.phase === "countdown" && players.length < c.QUICKPLAY_MIN_PLAYERS) {
            next = { ...next, phase: "lobby", deadline: null };
          }
        } else {
          // In a game: out of it, keeping their points.
          next = { ...r, players: r.players.map((x) => (x.id === id ? { ...x, left: true, connected: false, conn: null } : x)) };
        }
        empty = next.players.every((x) => x.left);
        return next;
      });
      if (!room) return;
      if (empty) {
        await d.store.deleteRoom(code);
        if (room.type === "public") await d.store.closeQuickplay(code);
        return;
      }
      broadcast(room);
    },

    async sync(code: string): Promise<Room> {
      const room = await d.store.getRoom(code);
      if (!room) throw new GameError("not_found");
      return room;
    },

    /** Moves a room whose phase ended to its next phase. Called by the sweeper, under the room's lease. */
    async advance(code: string): Promise<void> {
      const room = await d.store.getRoom(code);
      if (!room || room.deadline === null || room.deadline > now() - GRACE_MS) return;
      switch (room.phase) {
        case "countdown":
        case "results":
          return startRound(room);
        case "round":
          return evaluate(room);
        case "voting":
          return finishVote(room);
        default:
          // lobby and ended have no deadline; drop a stray one
          await d.store.updateRoom(code, (r) => (same(r, room) ? { ...r, deadline: null } : null));
      }
    },
  };

  async function startRound(seen: Room): Promise<void> {
    let pick: ReturnType<typeof pickRound> = null;
    try {
      pick = pickRound(await d.validator.categories(), new Set(seen.used), rng);
    } catch (err) {
      roomLog(seen).warn({ err: String(err) }, "no categories from the validator; trying again");
    }
    if (!pick) {
      await d.store.updateRoom(seen.code, (r) => (same(r, seen) ? { ...r, deadline: now() + RETRY_MS } : null));
      return;
    }
    const { category, letter } = pick;
    const deadline = now() + c.ROUND_SECONDS * 1000;
    const room = await d.store.updateRoom(seen.code, (r) =>
      same(r, seen)
        ? {
            ...r,
            phase: "round",
            round: r.round + 1,
            letter,
            category: { id: category.id, name: category.name },
            deadline,
            used: [...r.used, `${category.id}:${letter}`],
            startedAt: r.startedAt ?? now(),
            pending: null,
          }
        : null,
    );
    if (!room) return;
    if (room.round === 1 && room.type === "public") {
      await d.store.closeQuickplay(room.code);
      for (const p of room.players) d.metrics.matchmakingWaitSeconds.observe((now() - p.joinedAt) / 1000);
    }
    d.emit(room.code, "round:start", { round: room.round, letter, category: room.category, deadline, serverNow: now() });
    broadcast(room);
  }

  async function evaluate(seen: Room): Promise<void> {
    const answers = await d.store.answers(seen.code, seen.round);
    const category = seen.category!;
    const letter = seen.letter!;
    const evaluated: PendingAnswer[] = await Promise.all(
      seen.players.filter(isActive).map(async (p): Promise<PendingAnswer> => {
        const answer = cleanAnswer(answers.get(p.id) ?? "");
        const base = { playerId: p.id, nickname: p.nickname, answer };
        if (answer === "") return { ...base, verdict: "empty", key: "" };
        if (isBlocked(answer, "answer")) {
          d.metrics.filterBlockedTotal.inc({ field: "answer" });
          return { ...base, verdict: "blocked", key: "" };
        }
        const check = await d.validator.validate(category.id, letter, answer);
        // Without the validator's key, group identical answers by the filter's coarser form.
        const key = check.key || `~${filterCompact(answer)}`;
        return { ...base, verdict: check.result === "unavailable" ? "unknown" : check.result, key };
      }),
    );
    if (!evaluated.some((e) => e.verdict === "unknown")) return finish(seen, evaluated);
    const deadline = now() + c.VOTE_SECONDS * 1000;
    const room = await d.store.updateRoom(seen.code, (r) =>
      same(r, seen) ? { ...r, phase: "voting", pending: evaluated, deadline } : null,
    );
    if (!room) return;
    const items = evaluated
      .filter((e) => e.verdict === "unknown")
      .map(({ playerId, nickname, answer }) => ({ playerId, nickname, answer }));
    d.emit(room.code, "vote:start", { round: room.round, items, deadline, serverNow: now() });
    broadcast(room);
  }

  async function finishVote(seen: Room): Promise<void> {
    const votes = await d.store.votes(seen.code, seen.round);
    const evaluated = (seen.pending ?? []).map((p) =>
      p.verdict === "unknown" ? { ...p, accepted: voteAccepted(votes.get(p.playerId) ?? []) } : p,
    );
    return finish(seen, evaluated);
  }

  async function finish(seen: Room, evaluated: PendingAnswer[]): Promise<void> {
    const nicknames = new Map(evaluated.map((e) => [e.playerId, e.nickname]));
    const scored: Scored[] = scoreRound(evaluated);
    const result: RoundResult = {
      round: seen.round,
      letter: seen.letter!,
      category: seen.category!,
      answers: scored.map((s) => ({
        playerId: s.playerId,
        nickname: nicknames.get(s.playerId) ?? "",
        answer: s.answer,
        verdict: s.verdict,
        final: s.final,
        points: s.points,
        strike: s.strike,
      })),
    };
    let over = false;
    const room = await d.store.updateRoom(seen.code, (r) => {
      if (!same(r, seen)) return null;
      const players = applyScores(r.players, scored, c.MAX_STRIKES);
      over = isGameOver(players, r.round, r.maxRounds);
      return {
        ...r,
        players,
        pending: null,
        lastResults: result,
        phase: over ? "ended" : "results",
        deadline: over ? null : now() + c.RESULTS_SECONDS * 1000,
        winners: over ? winners(players) : null,
      };
    });
    if (!room) return;

    d.metrics.roundsTotal.inc();
    for (const s of scored) {
      const label = s.verdict === "unknown" ? (s.accepted ? "accepted" : "rejected") : s.verdict;
      d.metrics.answersTotal.inc({ result: label });
    }
    try {
      await d.store.appendAnswers(
        scored.map((s) => ({
          room: room.code,
          room_type: room.type,
          round: String(room.round),
          category: result.category.id,
          letter: result.letter,
          player: s.playerId,
          answer: s.answer,
          verdict: s.verdict === "unknown" ? (s.accepted ? "accepted" : "rejected") : s.verdict,
          points: String(s.points),
          at: new Date(now()).toISOString(),
        })),
      );
    } catch (err) {
      // The game goes on without its analytics record.
      d.metrics.redisErrorsTotal.inc();
      roomLog(room).warn({ err: String(err) }, "couldn't append answers to the stream");
    }
    const table = standings(room.players).map(({ id, nickname, score, strikes, eliminated }) => ({ id, nickname, score, strikes, eliminated }));
    d.emit(room.code, "round:results", { ...result, standings: table, serverNow: now() });
    if (over) {
      d.emit(room.code, "game:end", { winners: room.winners, standings: table });
      roomLog(room).info({ winners: room.winners }, "game ended");
    }
    broadcast(room);
  }

  return engine;
}

export type Engine = ReturnType<typeof createEngine>;
