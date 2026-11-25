# 0019. Keep game state, timers and matchmaking in Redis, advanced by whichever pod gets the lease

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The game server runs as several pods behind one load balancer, rolled and killed at will: rolling deploys, Karpenter spot reclaims, chaos tests in the test arena. A game must not notice:
- any pod can serve any player of any room, with no sticky sessions (CLAUDE.md → Architecture);
- rounds are server-authoritative: a 20-second timer, then evaluation, a vote and results, run by the server, not by clients;
- a round has to finish even if the pod that started it disappears mid-round;
- quick play has to match players who connected to different pods.

## Decision

- **State:** each room is one JSON value in Redis, `rb:room:<code>`. It's changed only by a compare-and-set Lua script: the write happens if the value is still the one that was read, and the change is retried otherwise. Answers, votes and resume-token hashes live in small hashes beside it, so concurrent answers don't contend with the room. Everything expires after `ROOM_TTL_SECONDS` (2 h) without activity.
- **Timers:** a sorted set, `rb:deadlines`, holds each room by the time its phase ends. The compare-and-set script updates it together with the room, so a room can't lose its timer between two writes.
  - Every pod sweeps the set every 200 ms (waiting 250 ms past a deadline for answers still in flight), and takes a 15 s lease on each due room before advancing it.
  - A transition applies only if the room is still in the phase, round and deadline it read. If two pods race, one write lands and the other is a no-op.
- **Fan-out:** Socket.IO's Redis adapter over pub/sub. An event emitted by the pod that advanced a room reaches its players on every pod.
- **Matchmaking:** `rb:quickplay:open` points at the public room new players join, moved by compare-and-set. A room closes to new players when it fills or starts.
- **Answer events** go to the stream `rb:answers`, trimmed near 100,000 entries, for the data pipeline.
- **The client:** node-redis 6, speaking RESP2 (the adapter's pub/sub expects it), failing commands at once while disconnected instead of queueing them.

## Alternatives considered

| Option | Why not |
|---|---|
| State in each pod's memory, with sticky sessions | A pod's death ends its games, and rolling deploys need connection draining for the length of a game. |
| `WATCH`/`MULTI` transactions | node-redis multiplexes one connection, and `WATCH` needs an isolated one (a pool of them). A Lua compare-and-set does the same in one round trip. |
| Redis keyspace notifications on expiring keys as timers | Expired-key events fire only when Redis gets around to expiring the key, aren't delivered to a subscriber that's reconnecting, and aren't persisted. A missed event is a stuck room. |
| A leader pod running every timer | Leader election, plus a failover gap during which every room stalls. With leases, any pod advances any room. |
| A job queue (BullMQ) for delayed transitions | Another dependency and its own Redis keys and workers, for what a sorted set and a lease do. |
| Socket.IO's connection state recovery | It replays missed packets from the pod's memory, or needs the streams adapter. An explicit resume token works on any pod, and the state comes from Redis. |

## Consequences

- **Good:**
  - any pod can die at any moment; the other pods finish its rounds (tested: a pod closed mid-round, the round completed on the other);
  - no sticky sessions, so rolling deploys and spot reclaims are routine;
  - memory is bounded by the TTL and the stream trim.
- **Bad / risks:**
  - phase changes happen up to about 450 ms after a deadline (sweep interval + grace);
  - a pod that dies while evaluating a round leaves its lease for up to 15 s, delaying that one room by as much;
  - every pod polls Redis 5 times a second (cheap, but it scales with the number of pods);
  - the multi-key script assumes one Redis. Redis Cluster would need hash-tagged keys (`rb:{<code>}:...`) and a per-slot deadline set;
  - if Redis is down, nothing works: readiness fails and events return `unavailable`. Redis is a hard dependency, and its availability is the game's.
- **Follow-ups:**
  - Redis with persistence and a replica in the cluster;
  - alerts on `game_redis_errors_total` and on rooms past their deadline (a stuck sweeper).

## How we'll know it was right

Pod-kill chaos during the test arena never fails a game, rolling deploys under load show no failed games, and Redis CPU stays low at the load-test target (300 rooms).
