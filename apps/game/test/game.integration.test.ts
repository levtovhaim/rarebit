// Game ↔ Redis, with several game servers as pods against one Redis (make game-integration starts
// a throwaway Redis and sets TEST_REDIS_URL). Without it, these tests are skipped.
import { createClient } from "redis";
import { io as connect, type Socket } from "socket.io-client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { call, client, next, REDIS_URL, startPod, testConfig, type Pod } from "./helpers.js";

// Tests in a file run one after another, which these need: they share one Redis.
const run = REDIS_URL ? describe : describe.skip;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, Math.max(0, ms)));

/** Waits for `check` to hold, for up to 3 s. */
async function until(check: () => Promise<boolean>): Promise<void> {
  for (let i = 0; i < 30; i++) {
    if (await check()) return;
    await sleep(100);
  }
  throw new Error("condition not met within 3 s");
}

run("the game against Redis", { timeout: 60_000 }, () => {
  const redis = createClient({ url: REDIS_URL, RESP: 2 });
  let pods: Pod[] = [];
  let sockets: Socket[] = [];

  beforeEach(async () => {
    if (!redis.isOpen) await redis.connect();
    await redis.flushDb();
  });

  afterEach(async () => {
    for (const s of sockets) s.disconnect();
    await Promise.allSettled(pods.map((p) => p.server.close()));
    pods = [];
    sockets = [];
  });

  async function pod(name: string, config = testConfig()) {
    const p = await startPod(name, config);
    pods.push(p);
    return p;
  }

  async function player(p: Pod) {
    const s = await client(p);
    sockets.push(s);
    return s;
  }

  /** A private room: the host on one pod, the guest on another. */
  async function privateRoom(hostPod: Pod, guestPod: Pod) {
    const host = await player(hostPod);
    const guest = await player(guestPod);
    const created = await call(host, "room:create", { nickname: "דני" });
    expect(created).toMatchObject({ ok: true, state: { phase: "lobby" } });
    const joined = await call(guest, "room:join", { roomCode: created.roomCode, nickname: "רותי" });
    expect(joined.ok).toBe(true);
    return { host, guest, created, joined };
  }

  it("plays a whole private game with the players on two pods", async () => {
    const [a, b] = [await pod("a"), await pod("b")];
    const { host, guest, created, joined } = await privateRoom(a, b);

    // Round 1: both pods' players get it, whichever pod's sweeper started it.
    const starts = [next(host, "round:start"), next(guest, "round:start")];
    expect((await call(guest, "game:start")).error).toBe("not_host");
    expect((await call(host, "game:start")).ok).toBe(true);
    const [r1, r1guest] = await Promise.all(starts);
    expect(r1).toMatchObject({ round: 1, letter: "א", category: { id: "country", name: "ארץ" } });
    expect(r1guest.round).toBe(1);
    expect(r1.deadline - r1.serverNow).toBeGreaterThan(2000);

    // The same answer in two spellings shares the points.
    expect((await call(host, "answer:submit", { round: 1, answer: "אוסטריה" })).ok).toBe(true);
    expect((await call(guest, "answer:submit", { round: 1, answer: "אסטריה" })).ok).toBe(true);
    const res1 = await next(guest, "round:results");
    const points = (r: any) => Object.fromEntries(r.answers.map((x: any) => [x.playerId, x.points]));
    expect(points(res1)).toEqual({ [created.playerId]: 5, [joined.playerId]: 5 });
    expect((await call(host, "answer:submit", { round: 1, answer: "late" })).error).toBe("not_accepting");

    // Round 2: a unique answer, and no answer (a strike). Then the game ends.
    const r2 = await next(host, "round:start");
    expect(r2.round).toBe(2);
    await call(host, "answer:submit", { round: 2, answer: "ארגנטינה" });
    const ended = next(guest, "game:end");
    const res2 = await next(host, "round:results");
    expect(points(res2)).toEqual({ [created.playerId]: 10, [joined.playerId]: 0 });
    const end = await ended;
    expect(end.winners).toEqual([created.playerId]);
    expect(end.standings.map((s: any) => [s.score, s.strikes])).toEqual([
      [15, 0],
      [5, 1],
    ]);

    // Every scored answer went to the stream for the data pipeline.
    expect(await redis.xLen("rb:answers")).toBe(4);
    const first = (await redis.xRange("rb:answers", "-", "+", { COUNT: 1 }))?.[0];
    expect(first?.message).toMatchObject({ room: created.roomCode, round: "1", category: "country", letter: "א" });
  });

  it("keeps the game going when the pod that was running it shuts down", async () => {
    const [a, b] = [await pod("a"), await pod("b")];
    const { host, guest, created, joined } = await privateRoom(a, a);
    const started = next(host, "round:start");
    await call(host, "game:start");
    await started;

    // Pod a dies with both players on it; they reconnect to pod b and resume from Redis.
    const dropped = new Promise((resolve) => (host.connected ? host.once("disconnect", resolve) : resolve(null)));
    await a.server.close();
    pods = pods.filter((p) => p !== a);
    await dropped;
    const host2 = await player(b);
    const guest2 = await player(b);
    const resumed = await call(host2, "room:resume", { roomCode: created.roomCode, playerId: created.playerId, token: created.token });
    expect(resumed).toMatchObject({ ok: true, state: { phase: "round", round: 1 } });
    expect((await call(guest2, "room:resume", { roomCode: created.roomCode, playerId: joined.playerId, token: "x".repeat(32) })).error).toBe("bad_token");
    expect((await call(guest2, "room:resume", { roomCode: created.roomCode, playerId: joined.playerId, token: joined.token })).ok).toBe(true);

    // Pod b's sweeper finishes the round the dead pod started.
    await call(host2, "answer:submit", { round: 1, answer: "אוסטריה" });
    const results = await next(guest2, "round:results");
    expect(results.round).toBe(1);
    expect(results.answers.find((x: any) => x.playerId === created.playerId).points).toBe(10);
    void guest;
  });

  it("sends an unknown answer to the room vote", async () => {
    const [a, b] = [await pod("a"), await pod("b")];
    const { host, guest, created, joined } = await privateRoom(a, b);
    const started = next(host, "round:start");
    await call(host, "game:start");
    await started;
    await call(host, "answer:submit", { round: 1, answer: "אטלנטיס" });
    await call(guest, "answer:submit", { round: 1, answer: "אוסטריה" });

    const vote = await next(guest, "vote:start");
    expect(vote.items).toEqual([{ playerId: created.playerId, nickname: "דני", answer: "אטלנטיס" }]);
    expect((await call(host, "vote:cast", { round: 1, playerId: created.playerId, accept: true })).error).toBe("not_allowed");
    expect((await call(guest, "vote:cast", { round: 1, playerId: created.playerId, accept: true })).ok).toBe(true);

    const results = await next(host, "round:results");
    const line = (id: string) => results.answers.find((x: any) => x.playerId === id);
    expect(line(created.playerId)).toMatchObject({ verdict: "unknown", final: "valid", points: 10 });
    expect(line(joined.playerId)).toMatchObject({ verdict: "valid", points: 10 });
  });

  it("matches three quick-play players across pods and starts after the countdown", async () => {
    const [a, b] = [await pod("a"), await pod("b")];
    const players = [await player(a), await player(b), await player(a)];
    const codes: string[] = [];
    for (const [i, s] of players.entries()) {
      const reply = await call(s, "quickplay:join", { nickname: "דני" });
      expect(reply.ok).toBe(true);
      codes.push(reply.roomCode);
      if (i === 1) expect(reply.state.players.map((p: any) => p.nickname)).toEqual(["דני", "דני 2"]);
    }
    expect(new Set(codes).size).toBe(1);
    const rounds = await Promise.all(players.map((s) => next(s, "round:start")));
    expect(rounds.every((r) => r.round === 1)).toBe(true);

    // The room has started: the next player gets a new one.
    const late = await call(await player(b), "quickplay:join", { nickname: "רותי" });
    expect(late.ok).toBe(true);
    expect(late.roomCode).not.toBe(codes[0]);
  });

  it("drains: readiness fails, then connected players are told to reconnect", async () => {
    const a = await pod("a");
    const s = await player(a);
    await call(s, "room:create", { nickname: "דני" });
    const told = next(s, "server:draining", () => true, 10_000);
    const draining = a.server.drain();
    const ready = await fetch(`http://127.0.0.1:${a.port}/readyz`);
    expect(ready.status).toBe(503);
    expect((await call(s, "room:create", { nickname: "רותי" })).error).toBe("draining");
    await told;
    await draining;
    pods = [];
  });

  it("accepts WebSockets only from the allowed origins", async () => {
    const a = await pod("a", testConfig({ ALLOWED_ORIGINS: "https://rarebit.example" }));
    const open = (origin: string) =>
      new Promise<boolean>((resolve) => {
        const s = connect(`http://127.0.0.1:${a.port}`, { transports: ["websocket"], reconnection: false, forceNew: true, extraHeaders: { origin } });
        sockets.push(s);
        s.once("connect", () => resolve(true));
        s.once("connect_error", () => resolve(false));
      });
    expect(await open("https://evil.example")).toBe(false);
    expect(await open("https://rarebit.example")).toBe(true);
    expect(await refused(a)).toEqual({ origin: 1 });
  });

  /** game_connections_refused_total by reason, from the pod's /metrics. */
  async function refused(p: Pod): Promise<Record<string, number>> {
    const text = await (await fetch(`http://127.0.0.1:${p.port}/metrics`)).text();
    const counts: Record<string, number> = {};
    for (const m of text.matchAll(/^game_connections_refused_total\{reason="([a-z_]+)"\} (\d+)$/gm)) counts[m[1]!] = Number(m[2]);
    return counts;
  }

  // Behind the ALB every connection comes from a load balancer address; the player's is in
  // X-Forwarded-For. With the hops right, the per-address cap applies to players, not to the ALB.
  it.each([
    { hops: "1", second: true, counts: {} },
    { hops: "0", second: false, counts: { per_ip: 1 } },
  ])("counts players by X-Forwarded-For with TRUSTED_PROXY_HOPS=$hops", async ({ hops, second, counts }) => {
    const a = await pod("a", testConfig({ TRUSTED_PROXY_HOPS: hops, MAX_CONNECTIONS_PER_IP: "1" }));
    const open = (player: string) =>
      new Promise<boolean>((resolve) => {
        const s = connect(`http://127.0.0.1:${a.port}`, {
          transports: ["websocket"],
          reconnection: false,
          forceNew: true,
          extraHeaders: { "x-forwarded-for": player },
        });
        sockets.push(s);
        s.once("connect", () => resolve(true));
        s.once("connect_error", () => resolve(false));
      });
    expect(await open("203.0.113.1")).toBe(true);
    expect(await open("203.0.113.2")).toBe(second);
    expect(await refused(a)).toEqual(counts);
  });

  /** A private room on one pod, started; resolves with round 1's round:start. */
  async function startedRoom(p: Pod) {
    const room = await privateRoom(p, p);
    const started = next(room.host, "round:start");
    expect((await call(room.host, "game:start")).ok).toBe(true);
    return { ...room, r1: await started };
  }

  it("isn't stopped by leftover deadline entries, and removes them", async () => {
    // More than one sweep's batch (20) of entries whose rooms are gone, all due long ago.
    const orphans = Array.from({ length: 25 }, (_, i) => ({ score: 1000 + i, value: `GONE${String(i).padStart(2, "0")}` }));
    await redis.zAdd("rb:deadlines", orphans);
    const a = await pod("a");
    const { r1 } = await startedRoom(a);
    expect(r1.round).toBe(1);
    expect(await redis.zScore("rb:deadlines", "GONE00")).toBeNull();
    await until(async () => (await redis.zCard("rb:deadlines")) === 1); // only the running room's
  });

  it("finishes the round when Redis drops every connection mid-game", async () => {
    const a = await pod("a");
    const { host, guest } = await startedRoom(a);
    await call(host, "answer:submit", { round: 1, answer: "אוסטריה" });
    await redis.sendCommand(["CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes"]);
    await redis.sendCommand(["CLIENT", "KILL", "TYPE", "pubsub", "SKIPME", "yes"]);
    const results = await next(guest, "round:results");
    expect(results.answers.find((x: any) => x.verdict === "valid")?.points).toBe(10);
    expect((await fetch(`http://127.0.0.1:${a.port}/readyz`)).status).toBe(200);
  });

  it("survives failed broadcasts while its publishing connection reconnects", async () => {
    const a = await pod("a");
    const { host } = await privateRoom(a, a);
    const pubId = (await redis.sendCommand(["CLIENT", "LIST"]))
      .toString()
      .split("\n")
      .find((line) => line.includes("name=rarebit-game:a:pub"))
      ?.match(/^id=(\d+)/)?.[1];
    expect(pubId).toBeDefined();
    // Redis refuses new connections (as during a failover), so the killed one can't come back yet.
    const maxClients = (await redis.configGet("maxclients")).maxclients ?? "10000";
    await redis.configSet("maxclients", "1");
    try {
      await redis.sendCommand(["CLIENT", "KILL", "ID", pubId!]);
      // Broadcasts now go out while the publishing connection is down; this pod's players still get them.
      const started = next(host, "round:start");
      expect((await call(host, "game:start")).ok).toBe(true);
      await started;
      expect((await fetch(`http://127.0.0.1:${a.port}/readyz`)).status).toBe(503);
    } finally {
      await redis.configSet("maxclients", maxClients);
    }
    await until(async () => (await fetch(`http://127.0.0.1:${a.port}/readyz`)).status === 200);
    const metrics = await (await fetch(`http://127.0.0.1:${a.port}/metrics`)).text();
    expect(metrics).toMatch(/game_redis_errors_total [1-9]/);
  });

  it("takes an answer until the deadline, by Redis's clock, and not after", async () => {
    const a = await pod("a");
    const { host, guest, created, r1 } = await startedRoom(a);
    // Deadlines are on the server's clock (Redis's); this process's clock can differ.
    const serverNow = (() => {
      const offset = r1.serverNow - Date.now();
      return () => Date.now() + offset;
    })();
    await sleep(r1.deadline - serverNow() - 300);
    expect((await call(host, "answer:submit", { round: 1, answer: "אוסטריה" })).ok).toBe(true);
    await sleep(r1.deadline - serverNow() + 60); // past the deadline, before the sweeper's grace ends
    expect((await call(guest, "answer:submit", { round: 1, answer: "ארגנטינה" })).error).toBe("too_late");
    const results = await next(host, "round:results");
    expect(results.answers.find((x: any) => x.playerId === created.playerId).points).toBe(10);
    expect(results.answers.find((x: any) => x.playerId !== created.playerId).verdict).toBe("empty");
  });

  it("never shows a blocked answer's text", async () => {
    const a = await pod("a");
    const { host, guest, created } = await startedRoom(a);
    await call(host, "answer:submit", { round: 1, answer: "fuck" });
    await call(guest, "answer:submit", { round: 1, answer: "אוסטריה" });
    const results = await next(guest, "round:results");
    expect(results.answers.find((x: any) => x.playerId === created.playerId)).toMatchObject({ answer: "", verdict: "blocked", points: 0 });
    const state = (await call(guest, "room:sync")).state;
    expect(JSON.stringify(state)).not.toContain("fuck");
    const stream = await redis.xRange("rb:answers", "-", "+");
    expect(JSON.stringify(stream)).not.toContain("fuck");
    const metrics = await (await fetch(`http://127.0.0.1:${a.port}/metrics`)).text();
    expect(metrics).toContain('game_filter_blocked_total{field="answer"} 1');
  });

  it("gives a socket one seat: joining another room leaves the first", async () => {
    const a = await pod("a");
    const { host, guest, joined } = await privateRoom(a, a);
    const left = next(host, "room:state", (s) => s.players.length === 1);
    expect((await call(guest, "room:create", { nickname: "רותי" })).ok).toBe(true);
    const state = await left;
    expect(state.players.map((p: any) => p.id)).not.toContain(joined.playerId);
  });

  it("gives a new token on resume, and closes the connection that held the seat", async () => {
    const [a, b] = [await pod("a"), await pod("b")];
    const { host, created } = await privateRoom(a, a);
    const closed = new Promise((resolve) => host.once("disconnect", resolve));
    const tab = await player(b);
    const resumed = await call(tab, "room:resume", { roomCode: created.roomCode, playerId: created.playerId, token: created.token });
    expect(resumed.ok).toBe(true);
    expect(resumed.token).not.toBe(created.token);
    await closed; // the old socket, on the other pod
    const again = await player(b);
    expect((await call(again, "room:resume", { roomCode: created.roomCode, playerId: created.playerId, token: created.token })).error).toBe("bad_token");
    expect((await call(again, "room:resume", { roomCode: created.roomCode, playerId: created.playerId, token: resumed.token })).ok).toBe(true);
  });

  it("closes a socket that keeps guessing room codes", async () => {
    const a = await pod("a");
    const s = await player(a);
    const closed = new Promise((resolve) => s.once("disconnect", resolve));
    for (let i = 0; i < 5; i++) expect((await call(s, "room:join", { roomCode: "ABCDEF", nickname: "דני" })).error).toBe("not_found");
    await closed;
  });

  it("limits the connections from one address", async () => {
    const a = await pod("a", testConfig({ MAX_CONNECTIONS_PER_IP: "2" }));
    const first = await player(a);
    await player(a);
    await expect(player(a)).rejects.toThrow("too_many_connections");
    first.disconnect();
    await sleep(100);
    expect((await player(a)).connected).toBe(true);
  });

  it("expires a lobby sooner than a game", async () => {
    const a = await pod("a", testConfig({ LOBBY_TTL_SECONDS: "60" }));
    const { host, created } = await privateRoom(a, a);
    const key = `rb:room:${created.roomCode}`;
    const lobby = await redis.pTTL(key);
    expect(lobby).toBeGreaterThan(0);
    expect(lobby).toBeLessThanOrEqual(60_000);
    expect(await redis.pTTL(`${key}:t`)).toBeGreaterThan(0);
    const started = next(host, "round:start");
    await call(host, "game:start");
    await started;
    expect(await redis.pTTL(key)).toBeGreaterThan(60_000);
  });

  it("refuses offensive nicknames and exposes the game metrics", async () => {
    const a = await pod("a");
    const s = await player(a);
    expect((await call(s, "room:create", { nickname: "fuck you" })).error).toBe("nickname_blocked");
    expect((await call(s, "room:create", { nickname: "x" })).error).toBe("bad_nickname");
    expect((await call(s, "room:join", { roomCode: "not-a-code", nickname: "דני" })).error).toBe("bad_request");
    await call(s, "room:create", { nickname: "דני" });

    const health = await fetch(`http://127.0.0.1:${a.port}/healthz`);
    expect(health.status).toBe(200);
    expect((await fetch(`http://127.0.0.1:${a.port}/readyz`)).status).toBe(200);
    expect(await (await fetch(`http://127.0.0.1:${a.port}/version`)).json()).toMatchObject({ version: "unknown" });
    const metrics = await (await fetch(`http://127.0.0.1:${a.port}/metrics`)).text();
    for (const line of [
      'game_filter_blocked_total{field="nickname"} 1',
      'game_rooms_active{type="private"} 1',
      "game_players_connected 1",
      "game_draining 0",
      "game_matchmaking_queue_length 0",
      "nodejs_eventloop_lag_seconds",
    ]) {
      expect(metrics).toContain(line);
    }
  });
});
