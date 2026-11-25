# 0021. Run game timers from a deadline set that every pod sweeps, under per-room leases

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

Every phase of a room ends at a deadline: the countdown, the round, the vote, the results. Something has to move the room on when that time comes (ADR 0019 keeps the room itself in Redis):
- the pod that started a round may be gone when it ends (a rollout, a spot reclaim, a crash);
- two pods must never apply the same transition twice (double scoring, a skipped round);
- a room whose transition failed (the validator down, Redis blipping) must be retried, without holding up the other rooms;
- pods' clocks differ by a little, and a deadline the players see must be the one the server enforces.

## Decision

- **The deadline set:** a sorted set, `rb:deadlines`, holds each room by the epoch milliseconds its phase ends. The compare-and-set script that writes a room updates its entry in the same step, so a room can't lose its timer between two writes, and deleting a room removes its entry in the same step too.
- **The sweep:** every pod reads the 20 most overdue entries every 200 ms, waiting 250 ms past a deadline for answers still in flight. The next sweep starts 200 ms after the previous one finished, so a slow Redis can't stack sweeps up.
- **Leases:** before advancing a room, a pod takes `rb:lease:<code>` for 15 s (longer than the slowest evaluation). The same script pushes the room's entry 15 s forward, a visibility timeout: a room being advanced, or failing to be, leaves the front of the queue, so it can't starve the others.
- **Settle:** after advancing (or failing to), the pod puts the entry back at the room's real deadline, or removes it if the room is gone or has no deadline, then releases the lease. Entries older than the room TTL are pruned every minute.
- **Idempotent transitions:** a transition applies only if the room is still in the phase, round and deadline it read. If two pods race, one write lands and the other is a no-op.
- **One clock:** every pod measures its offset from Redis's `TIME` at start and every 30 s, and computes deadlines on that clock. Redis checks an answer's deadline against its own clock.
- **Retries:** when a round can't start (no categories from the validator), the room waits 2 s, 4 s, 8 s, then every 10 s, and its state carries a notice the players see.

## Alternatives considered

| Option | Why not |
|---|---|
| A `setTimeout` in the pod that started the phase | The timer dies with the pod, and the room stalls. |
| Redis keyspace notifications on expiring keys | Expired-key events fire only when Redis gets around to expiring the key, aren't delivered to a subscriber that's reconnecting, and aren't persisted. A missed event is a stuck room. |
| A leader pod running every timer | Leader election, plus a failover gap during which every room stalls. With leases, any pod advances any room. |
| A job queue (BullMQ) for delayed transitions | Another dependency with its own keys and workers, for what a sorted set and a lease do. |

## Consequences

- **Good:**
  - any pod can die at any moment, and the others finish its rounds (tested: a pod shut down mid-round, and the round completed on the other);
  - a leftover entry for a room that's gone can't block the queue: the first sweep that reaches it removes it (tested with more entries than a sweep's batch);
  - one room that keeps failing is retried at most every 15 s and never delays the rest.
- **Bad / risks:**
  - phase changes happen up to about 450 ms after a deadline (sweep interval + grace);
  - a pod that dies while advancing a room delays that room by up to its 15 s lease;
  - every pod polls Redis 5 times a second: cheap, but it grows with the number of pods;
  - a pod whose clock jumps between two syncs uses a wrong offset for up to 30 s; the answer deadline itself is still Redis's.
- **Follow-ups:**
  - an alert on rooms past their deadline by more than a lease (a stuck sweeper).

## How we'll know it was right

Pod kills during the test arena never stall or double-score a round, and the oldest overdue entry in `rb:deadlines` stays under a second behind its deadline at the load-test target.
