// One game played by a set of bots, start to finish, and the verdict on it. The game flow seats
// the bots, then reacts to the server: it answers each round and votes through the Strategy,
// and takes the room snapshot as the truth after a reconnect (a missed round:start still gets
// its answer). A game fails when it doesn't end, stalls past a deadline, loses a bot, gets an
// error code a well-behaved client never should, or ends with scores that don't add up.
import { BotClient } from "./client.js";
import type { Logger } from "./log.js";
import { EXPECTED_ERRORS, type GameEnd, type Reply, type RoomSnapshot, type RoundResults, type RoundStart, type VoteStart } from "./protocol.js";
import { fork, type Rng } from "./rng.js";
import type { Stats } from "./stats.js";
import type { Strategy } from "./strategy.js";
import type { WordLists } from "./words.js";

export interface GameDeps {
  urls: string[];
  socketPath: string;
  origin: string | undefined;
  words: WordLists;
  strategy: Strategy;
  log: Logger;
  stats: Stats;
  rng: Rng;
  ackTimeoutMs: number;
  reconnectGiveUpMs: number;
}

export interface GameSpec {
  mode: "private" | "quickplay";
  players: number;
  /** The whole game, from connecting to the last bot seeing the end. */
  timeoutMs: number;
  /** How long a phase may sit past its deadline: longer than a lease (15 s) plus a sweep. */
  stallGraceMs: number;
  /** Bots spread across the URLs starting here. */
  urlOffset: number;
  /** Aborts the game: it ends as "aborted", not as a failure. */
  signal?: AbortSignal;
}

export interface GameReport {
  ok: boolean;
  aborted: boolean;
  mode: GameSpec["mode"];
  room: string | null;
  players: number;
  rounds: number;
  duration_ms: number;
  winners: string[] | null;
  failure: string | null;
  checks: { ended: boolean; winners_agree: boolean | null; scores: "ok" | "skipped" | "mismatch" };
  reconnects: number;
  resumes: number;
  unexpected_errors: string[];
}

class Failure extends Error {}
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const describe = (err: unknown) => (err instanceof Error ? err.message : String(err));

export async function playGame(d: GameDeps, spec: GameSpec): Promise<GameReport> {
  const started = Date.now();
  const bots = Array.from(
    { length: spec.players },
    (_, i) =>
      new BotClient({
        urls: d.urls,
        startAt: spec.urlOffset + i,
        socketPath: d.socketPath,
        origin: d.origin,
        log: d.log.child({ bot: i + 1 }),
        stats: d.stats,
        rng: fork(d.rng),
        ackTimeoutMs: d.ackTimeoutMs,
        reconnectGiveUpMs: d.reconnectGiveUpMs,
      }),
  );
  const botRngs = bots.map(() => fork(d.rng));
  const results = new Map<number, RoundResults>();
  const endings = new Map<number, GameEnd | null>(); // bot index -> game:end (null: saw "ended" in a snapshot)
  const answered = bots.map(() => new Set<number>());
  const voted = bots.map(() => new Set<number>());
  const unexpected: string[] = [];
  let failure: string | null = null;
  let finished = false;
  let room: string | null = null;

  const failGame = (why: string) => {
    failure ??= why;
  };
  const classify = (event: string, reply: Reply) => {
    if (reply.ok || EXPECTED_ERRORS[event]?.includes(String(reply.error))) return;
    unexpected.push(`${event}: ${reply.error}`);
  };
  const mine = (i: number) => bots[i]!.seat?.playerId ?? "";
  const out = (s: RoomSnapshot | null, i: number) => s?.players.some((p) => p.id === mine(i) && (p.eliminated || p.left)) ?? false;

  async function answerRound(i: number, r: Pick<RoundStart, "round" | "letter" | "category" | "deadline" | "serverNow">) {
    const bot = bots[i]!;
    if (answered[i]!.has(r.round) || out(bot.state, i)) return;
    answered[i]!.add(r.round);
    const plan = await d.strategy.answer({ ...r, me: { playerId: mine(i), index: i }, words: d.words, rng: botRngs[i]! });
    if (!plan) return;
    await sleep(plan.afterMs);
    if (finished) return;
    const reply = await bot.call("answer:submit", { round: r.round, answer: plan.text }).catch((err: unknown) => ({ ok: false, error: `no reply (${describe(err)})` }));
    classify("answer:submit", reply);
  }

  async function voteRound(i: number, round: number, items: VoteStart["items"]) {
    const bot = bots[i]!;
    if (voted[i]!.has(round) || bot.state?.players.find((p) => p.id === mine(i))?.left) return;
    voted[i]!.add(round);
    for (const item of items) {
      if (item.playerId === mine(i)) continue;
      const accept = await d.strategy.vote({ round, item, me: { playerId: mine(i), index: i }, rng: botRngs[i]! });
      if (accept === null || finished) continue;
      const reply = await bot.call("vote:cast", { round, playerId: item.playerId, accept }).catch((err: unknown) => ({ ok: false, error: `no reply (${describe(err)})` }));
      classify("vote:cast", reply);
    }
  }

  bots.forEach((bot, i) => {
    bot.on("round:start", (r: RoundStart) => void answerRound(i, r));
    bot.on("vote:start", (v: VoteStart) => void voteRound(i, v.round, v.items));
    bot.on("round:results", (r: RoundResults) => results.set(r.round, r));
    bot.on("game:end", (e: GameEnd) => endings.set(i, e));
    bot.on("fatal", (reason: string) => failGame(`bot ${i + 1}: ${reason}`));
    // The snapshot is the truth: after a reconnect it may be the only news of a round or a vote.
    bot.on("state", (s: RoomSnapshot) => {
      if (s.lastResults) results.set(s.lastResults.round, s.lastResults);
      if (s.phase === "round" && s.letter && s.category && s.deadline !== null) {
        void answerRound(i, { round: s.round, letter: s.letter, category: s.category, deadline: s.deadline, serverNow: s.serverNow });
      }
      if (s.phase === "voting" && s.voting) void voteRound(i, s.round, s.voting);
      if (s.phase === "ended" && !endings.has(i)) endings.set(i, null);
    });
  });

  let aborted = false;
  // Once one bot has seen the end, the others must within the time a reconnect may take.
  const endSpreadMs = d.reconnectGiveUpMs + 5000;
  let firstEndAt = 0;
  try {
    await Promise.all(bots.map((b) => b.connect()));
    await seat(bots, spec, d.strategy, (code) => (room = code));
    if (spec.mode === "private") {
      const start = await bots[0]!.call("game:start", {});
      if (!start.ok) throw new Failure(`game:start: ${start.error}`);
    }
    await new Promise<void>((resolve, reject) => {
      const tick = setInterval(() => {
        const stop = (fn: () => void) => {
          clearInterval(tick);
          fn();
        };
        if (failure) return stop(() => reject(new Failure(failure!)));
        if (spec.signal?.aborted) {
          aborted = true;
          return stop(() => reject(new Failure("aborted")));
        }
        if (bots.every((_, i) => endings.has(i))) return stop(resolve);
        if (endings.size > 0 && firstEndAt === 0) firstEndAt = Date.now();
        if (firstEndAt > 0 && Date.now() - firstEndAt > endSpreadMs) {
          const missing = bots.map((_, i) => i + 1).filter((n) => !endings.has(n - 1));
          return stop(() => reject(new Failure(`the game ended, but bot ${missing.join(", ")} never saw the end`)));
        }
        const s = freshest(bots);
        if (Date.now() - started > spec.timeoutMs) {
          return stop(() => reject(new Failure(`no end within ${spec.timeoutMs} ms (${where(s)})`)));
        }
        if (s?.deadline != null) {
          const late = bots[0]!.serverNow() - s.deadline;
          if (late > spec.stallGraceMs) return stop(() => reject(new Failure(`stalled: ${where(s)}, ${late} ms past its deadline`)));
        }
      }, 250);
    });
  } catch (err) {
    failGame(describe(err));
  } finally {
    finished = true;
    for (const b of bots) b.close();
  }

  // The verdict.
  const ended = bots.every((_, i) => endings.has(i));
  const finals = bots.map((b, i) => endings.get(i)?.winners ?? (b.state?.phase === "ended" ? b.state.winners : null));
  const known = finals.filter((w): w is string[] => w !== null).map((w) => [...w].sort().join(","));
  const winnersAgree = known.length === 0 ? null : new Set(known).size === 1;
  const final = [...endings.values()].find((e): e is GameEnd => e !== null);
  const last = freshest(bots);
  const rounds = last?.round ?? Math.max(0, ...results.keys());
  let scores: GameReport["checks"]["scores"] = "skipped";
  if (ended && final) {
    const complete = Array.from({ length: rounds }, (_, k) => results.has(k + 1)).every(Boolean);
    if (complete) {
      scores = "ok";
      for (const s of final.standings) {
        const points = [...results.values()].reduce((sum, r) => sum + (r.answers.find((a) => a.playerId === s.id)?.points ?? 0), 0);
        const strikes = [...results.values()].reduce((sum, r) => sum + (r.answers.find((a) => a.playerId === s.id)?.strike ? 1 : 0), 0);
        if (points !== s.score || strikes !== s.strikes) {
          scores = "mismatch";
          failGame(`scores don't add up for ${s.nickname}: standings ${s.score} points and ${s.strikes} strikes, the rounds ${points} and ${strikes}`);
        }
      }
    }
  }
  if (ended && winnersAgree === false) failGame(`the bots disagree on the winners: ${[...new Set(known)].join(" vs ")}`);
  if (!failure && unexpected.length > 0) failGame(`unexpected replies: ${[...new Set(unexpected)].join("; ")}`);

  return {
    ok: failure === null,
    aborted,
    mode: spec.mode,
    room,
    players: spec.players,
    rounds,
    duration_ms: Date.now() - started,
    winners: final?.winners ?? finals.find((w) => w !== null) ?? null,
    failure: aborted ? "aborted" : failure,
    checks: { ended, winners_agree: winnersAgree, scores },
    reconnects: bots.reduce((n, b) => n + b.reconnects, 0),
    resumes: bots.reduce((n, b) => n + b.resumes, 0),
    unexpected_errors: [...new Set(unexpected)],
  };
}

async function seat(bots: BotClient[], spec: GameSpec, strategy: Strategy, onRoom: (code: string) => void): Promise<void> {
  if (spec.mode === "private") {
    const created = await bots[0]!.create(strategy.nickname(0));
    if (!created.ok) throw new Failure(`room:create: ${created.error}`);
    const code = bots[0]!.seat!.roomCode;
    onRoom(code);
    for (let i = 1; i < bots.length; i++) {
      const joined = await bots[i]!.join(code, strategy.nickname(i));
      if (!joined.ok) throw new Failure(`room:join: ${joined.error}`);
    }
    return;
  }
  for (let i = 0; i < bots.length; i++) {
    const joined = await bots[i]!.quickplay(strategy.nickname(i));
    if (!joined.ok) throw new Failure(`quickplay:join: ${joined.error}`);
  }
  const rooms = new Set(bots.map((b) => b.seat!.roomCode));
  onRoom([...rooms].join(","));
  if (rooms.size > 1) throw new Failure(`quick play put the bots in ${rooms.size} rooms`);
}

function freshest(bots: BotClient[]): RoomSnapshot | null {
  return bots.map((b) => b.state).reduce<RoomSnapshot | null>((a, s) => (!s ? a : !a || s.serverNow > a.serverNow ? s : a), null);
}

function where(s: RoomSnapshot | null): string {
  if (!s) return "no state yet";
  return `phase ${s.phase}, round ${s.round}${s.notice ? `, notice ${s.notice}` : ""}`;
}
