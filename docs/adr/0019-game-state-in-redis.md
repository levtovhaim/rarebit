# 0019. Keep game state and matchmaking in Redis, changed only by compare-and-set

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The game server runs as several pods behind one load balancer, rolled and killed at will: rolling deploys, Karpenter spot reclaims, chaos tests in the test arena. A game must not notice:
- any pod can serve any player of any room, with no sticky sessions (CLAUDE.md → Architecture);
- rounds are server-authoritative: the server runs the timer, the evaluation, the vote and the results, not the clients;
- a round has to finish even if the pod that started it disappears mid-round (how timers survive that is ADR 0021);
- quick play has to match players who connected to different pods.

## Decision

- **State:** each room is one JSON value in Redis, `rb:room:<code>`. It's changed only by a compare-and-set Lua script: the write happens if the value is still the one that was read, and the change is retried otherwise.
- **Beside the room:** answers, votes and resume-token hashes live in small hashes, so concurrent answers don't contend with the room.
  - An answer or a vote is checked and written in one Lua script, against Redis's clock: an acknowledged answer is always one the evaluation reads.
  - A token is written only while its room exists, and expires with it.
- **Expiry:** a room's keys expire `LOBBY_TTL_SECONDS` (10 min) after the last change while it waits in the lobby or after its game ended, and `ROOM_TTL_SECONDS` (2 h) after the last change during a game.
- **Fan-out:** Socket.IO's Redis adapter over pub/sub. An event emitted by the pod that advanced a room reaches its players on every pod.
- **Matchmaking:** `rb:quickplay:open` points at the public room new players join, moved by compare-and-set. A room closes to new players when it fills or starts, and opens again if a seat frees up before it starts.
- **Answer events** go to the stream `rb:answers`, trimmed near 100,000 entries, for the data pipeline.
- **The clients:** node-redis 6, speaking RESP2 (the adapter's pub/sub expects it), failing commands at once while disconnected instead of queueing them. The adapter publishes on a client of its own whose publish failures are counted, not thrown.

## Alternatives considered

| Option | Why not |
|---|---|
| State in each pod's memory, with sticky sessions | A pod's death ends its games, and rolling deploys need connection draining for the length of a game. |
| `WATCH`/`MULTI` transactions | node-redis multiplexes one connection, and `WATCH` needs an isolated one (a pool of them). A Lua compare-and-set does the same in one round trip. |
| One Redis hash per room, a field per attribute | Partial updates contend less, but every transition reads and writes most fields anyway, and a hash can't be compared and swapped as a whole in one step. |
| Postgres for room state | Durable, but a round trip per answer and per transition, plus a connection pool sized for every pod; the state lives for minutes and is cheap to lose. |

## Consequences

- **Good:**
  - any pod serves any room; no sticky sessions, so rolling deploys and spot reclaims are routine;
  - memory is bounded by the TTLs and the stream trim;
  - two pods changing the same room can't both win: the second retries against the new value.
- **Bad / risks:**
  - the multi-key scripts assume one Redis. Redis Cluster would need hash-tagged keys (`rb:{<code>}:...`) and a per-slot deadline set;
  - if Redis is down, nothing works: readiness fails and events return `unavailable`. Redis is a hard dependency, and its availability is the game's;
  - an eviction policy other than `noeviction` could drop a room mid-game; the Redis this runs on must not evict;
  - the keys have no per-environment prefix: environments need a Redis (or a database number) each.
- **Follow-ups:**
  - Redis with persistence and a replica, and the client's behavior on failover (a read-only replica, a connection that hangs);
  - alerts on `game_redis_errors_total`.

## How we'll know it was right

Pod-kill chaos during the test arena never fails a game, rolling deploys under load show no failed games, and Redis CPU stays low at the load-test target.
