# 0014. Run schema migrations and the word-list load from the validator binary, as a Job

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The validator reads tables that something has to create and fill:
- the schema changes with the validator's code, so a rollout must migrate before new pods start;
- word lists live in git (`data/`, ADR 0012) and reach Postgres only through one loader, never through ad-hoc writes;
- each entry's keys are computed by `native/hebrew-normalize`, the same code `serve` uses on answers, or lookups silently stop matching;
- in Kubernetes the migration runs as a Job, which can be retried, started twice by overlapping rollouts, or lose its pod mid-run.

## Decision

- **`validator migrate`**, a mode of the validator binary (same image, same library), does both jobs in order: the schema migrations (runner: ADR 0016), then the content load. It runs as a Job before each rollout.
- **The content load** reads and checks every category file before touching the database, then replaces the lists in one transaction. Readers see the old lists until it commits. It's skipped when the files' hash and the normalizer version match the last row in `content_loads`, so running it on every deploy is cheap.
- **Categories are never deleted.** A category whose file is gone is retired (`retired_at`) and its lists emptied, so tables that reference categories keep their rows, and restoring the file brings it back. `words` and `word_lists` are rewritten on every load: nothing may point a foreign key at them.
- **A lost Job pod can't block deploys for long.** The migrate session asks Postgres to end it when idle for 30 s and sets TCP keepalives and a TCP user timeout, so a run whose pod or node vanished frees the migration lock within about 30 s instead of the operating system's 2 hours. Once it holds the lock, a migration waits at most 5 s for a table lock and fails, so the Job retries instead of queueing every reader behind it.
- **Database roles:** `migrate` connects as the owner of the tables; `serve` should connect as a role with only `SELECT` on `categories`, `words` and `content_loads`, so code running on player input can't change the word lists. Both use TLS (`sslmode=verify-full`). The chart wires the two Secrets.
- `migrate` connects directly to the primary: the session-level advisory lock doesn't survive a transaction-mode connection pooler.

## Alternatives considered

| Option | Why not |
|---|---|
| Migrate at `serve` startup | Every pod races to migrate, a slow migration delays readiness, and a failed one crash-loops the whole Deployment instead of failing one Job. |
| A separate loader image or language | The keys must come from the same normalizer build that `serve` uses. A second image would need the same cgo build and could drift. |
| Load by diff (insert/delete only the changed words) | Less write volume, but a full replace can't drift, and it's cheap: loading the 1,249 seed words took about 80 ms locally. |
| Delete removed categories | A dropped file (or a packaging mistake) would delete that category's history in every table that references it, or block every deploy if the reference forbids it. |

## Consequences

- **Good:**
  - one image to build, scan and pin;
  - concurrent, retried and abandoned runs are safe;
  - a no-op run costs one query;
  - content history survives category removals.
- **Bad / risks:**
  - **normalizer skew during rollouts:** the Job rewrites every key with the new normalizer while old pods still normalize answers with the old one, so lookups can miss until the rollout ends. Today a metric and a warning detect it (ADR 0015); keeping keys per normalizer version is [issue 24](https://github.com/levtovhaim/rarebit/issues/24), due before the library's normalization rules first change;
  - the Job needs the data files: they ship in the image or are mounted, a packaging choice made with the Dockerfile and the chart;
  - forward-only migrations need expand/contract discipline in review (ADR 0016).
- **Follow-ups:**
  - the Job, run before each rollout (Argo CD sync wave or a Helm hook);
  - the `rarity` mode in the same binary;
  - an alert on a failed migrate Job ([issue 23](https://github.com/levtovhaim/rarebit/issues/23)).

## How we'll know it was right

Migrate Jobs stay idempotent (a rerun logs `migrations_applied: 0, content_changed: false`), no rollout ever starts pods against an unmigrated schema, and no deploy is blocked by a lock a dead run left behind.
