# 0013. Serve validation as an HTTP/JSON API that looks up Postgres on every request

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The game server (Node.js) asks the validator about each answer at the end of a round: a room of 6 players and 6 categories makes 36 checks within a second or two. The validator needs:
- a protocol the game, the bots, `curl` and the shared ALB all speak;
- the runtime contract every service follows: `/healthz`, `/readyz`, `/metrics`, `/version` (CLAUDE.md → Rules, rule 7);
- to see word-list changes as soon as the content load commits, without a restart.

The word lists are small today (1,249 words), and every lookup hits an index.

## Decision

- **Protocol:** HTTP/1.1 with JSON bodies, one answer per request: `POST /v1/validate` with `{category, letter, answer}`. The runtime endpoints sit on the same port. The path carries a version (`/v1`), so an incompatible change gets `/v2` while the old path keeps working during a rollout.
- **Errors:** a caller mistake (unknown category, a bad letter, a malformed body) is a 400 with an error code. A database failure is a 503, which the game treats like an `unknown` answer (the room votes), so a validator outage slows a round down but doesn't stop it.
- **Lookups:** every request reads Postgres through a connection pool, with up to three indexed queries (exact key, spelling key, typo candidates). No in-process copy of the lists yet.
- **Readiness** includes Postgres (one query, 1 s timeout) and the first content load; liveness never does.

## Alternatives considered

| Option | Why not |
|---|---|
| gRPC | Typed contracts and HTTP/2 multiplexing, but it needs generated code in Go and Node, gRPC health checks, and ALB gRPC target groups. Nothing here needs streaming or that throughput. |
| A batch endpoint (all of a round's answers in one call) | Fewer round trips, but a more complex contract before there's a measurement. Add it if load tests show the per-answer calls cost too much. |
| The word lists in memory, refreshed on a timer | Faster and no database on the hot path, but every pod holds a copy, content changes show up late, and memory grows with the lists. Revisit if Postgres becomes the bottleneck. |
| Readiness without the database | All pods would stay "ready" and answer 503 during an outage. With the database in readiness the Service has no endpoints, and the game gets a fast connection error instead: the same fallback, sooner. |

## Consequences

- **Good:**
  - debuggable with `curl`;
  - no generated code;
  - content changes are live as soon as the load commits;
  - one port for the API and the probes.
- **Bad / risks:**
  - one HTTP request per answer;
  - Postgres is on the hot path, so its latency is the validator's latency;
  - when Postgres is down, every validator pod goes unready together. That's intended, but the alerting has to treat it as a Postgres incident, not a validator one.
- **Follow-ups:**
  - load-test the round-end burst (bots);
  - an SLO on `/v1/validate` latency and errors when the monitoring stack exists;
  - an HPA on CPU.

## How we'll know it was right

At the load-test target (300 rooms), round-end validation p99 stays under the game's answer-acknowledgement budget, and Postgres CPU stays low. If not, add the batch endpoint or the in-memory cache, in that order.
