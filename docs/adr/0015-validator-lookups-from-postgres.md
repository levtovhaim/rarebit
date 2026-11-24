# 0015. Look up Postgres on every validation, and include the database in readiness

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

Each validation needs the word lists of one category. They're small today (1,249 words) and change only when a content load commits (ADR 0014). Two questions follow:
- where `serve` reads them from: Postgres on every request, or a copy in each pod;
- what `/readyz` means: Kubernetes sends traffic only to ready pods, and a validator can't answer anything without its word lists.

## Decision

- **Lookups:** every request reads Postgres through a connection pool, with up to four indexed queries (the category, the exact key, the spelling key, the typo candidates). No in-process copy of the lists.
- **Timeouts:** every layer has its own, so none waits on the next:
  - the whole validation: 3 s;
  - in Postgres: `statement_timeout` 2.5 s and `lock_timeout` 1 s, so a query the client gave up on doesn't keep running;
  - each new connection and each dial: 2 s. pgx would otherwise allow 2 minutes per connection, and no limit for the dial of the cancel request it sends when a connection breaks, during which the broken connection keeps its pool slot.
- **Readiness** includes the database: `/readyz` is 200 when Postgres answers within 1 s, the schema is at least at the binary's newest migration, and the word lists were loaded at least once. It's 503 while draining. Liveness (`/healthz`) never checks the database.
- **The readiness check has its own connection, outside the pool.** The probe isn't stuck behind busy request traffic, and a broken connection is dropped at once instead of holding a slot.
- **A normalizer mismatch doesn't fail readiness.** When the loaded keys came from another normalizer version than the running binary's, a metric and a warning say so (rollout skew, ADR 0014), because failing readiness would take every old pod out at once.

## Alternatives considered

| Option | Why not |
|---|---|
| The word lists in memory, refreshed on a timer | Faster, and no database on the hot path, but every pod holds a copy, content changes show up late, and memory grows with the lists. Revisit if Postgres becomes the bottleneck. |
| Readiness without the database | During an outage all pods stay "ready" and answer 503. With the database in readiness the Service has no endpoints, and the game gets a fast connection error instead: the same fallback, sooner. |
| The probe through the request pool, or a one-connection pool | Under load the probe would wait behind requests and fail, taking busy pods out one by one. A one-connection pool was tried: when its connection broke, pgx kept the slot for up to 15 s while closing it, so readiness stayed failed for 16 s after the database was back. |

## Consequences

- **Good:**
  - content changes are live as soon as the load commits;
  - a database outage shows up as unready pods, which routing already understands;
  - measured locally: after a database stall, lookups and readiness work again 1.5 s after it answers.
- **Bad / risks:**
  - Postgres is on the hot path, so its latency is the validator's latency;
  - when Postgres is down, every validator pod goes unready together. That's intended, but alerting must treat it as a Postgres incident;
  - each pod holds one connection more than `DB_MAX_CONNS`, for the probe.
- **Follow-ups:**
  - an SLO on `/v1/validate` latency and errors with the monitoring stack ([issue 23](https://github.com/levtovhaim/rarebit/issues/23));
  - an HPA on CPU.

## How we'll know it was right

At the load-test target, validation p99 stays within budget and Postgres CPU stays low, and pods never flap unready under load alone. If Postgres becomes the bottleneck, add the in-memory copy.
