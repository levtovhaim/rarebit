# 0014. Run schema migrations and the word-list load from the validator binary

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The validator reads tables that something has to create and fill:
- the schema changes with the validator's code, so a rollout must migrate before new pods start;
- word lists live in git (`data/`, ADR 0012) and reach Postgres only through one loader, never through ad-hoc writes;
- each entry's keys are computed by `native/hebrew-normalize`, the same code `serve` uses on answers, or lookups silently stop matching;
- in Kubernetes, the migration runs as a Job that can be retried, or started twice by overlapping rollouts.

## Decision

- **`validator migrate`**, a mode of the validator binary (same image, same library), does both jobs in order: schema migrations, then the content load.
- **Migrations** are plain SQL files embedded in the binary (`internal/migrate/migrations/NNNN_name.sql`), applied in order, each in its own transaction, and recorded in `schema_migrations` with a SHA-256. An applied migration whose file changed stops the run. Forward only: a rollback deploys an older image that must still work with the newer schema (expand, then contract).
- **Concurrency:** the run holds a session-level Postgres advisory lock. A second run waits for it, and the lock goes away with a crashed run's connection.
- **The content load** reads and checks every category file before touching the database, then replaces the lists in one transaction. Readers see the old lists until it commits. Categories are upserted, not recreated, so later tables can reference them. The load is skipped when the files' hash and the normalizer version match the last row in `content_loads`, so running it on every deploy is cheap.

## Alternatives considered

| Option | Why not |
|---|---|
| A migration tool (golang-migrate, goose, Atlas, Flyway) | Another dependency and CLI to replace about 100 lines of runner. Their extras (down migrations, drift detection) aren't needed yet. Atlas is worth a second look if the schema grows. |
| Migrate at `serve` startup | Every pod races to migrate, a slow migration delays readiness, and a failed one crash-loops the whole Deployment instead of failing one Job. |
| A separate loader image or language | The keys must come from the same normalizer build `serve` uses. A second image would need the same cgo build and could drift. |
| Load by diff (insert/delete only the changed words) | Less write volume, but a full replace can't drift, and it's cheap: the first migration plus the load of the 1,249 seed words took under 0.1 s locally. |

## Consequences

- **Good:**
  - one image to build, scan and pin;
  - the keys always match the running normalizer;
  - concurrent and retried runs are safe;
  - a no-op run costs one query.
- **Bad / risks:**
  - SQL runs inside a transaction, so `CREATE INDEX CONCURRENTLY` needs a different path when a table grows large;
  - forward-only migrations need expand/contract discipline in review;
  - the Job needs the data files: they ship in the image or are mounted, a packaging choice made with the Dockerfile and the chart.
- **Follow-ups:**
  - the Job, run before each rollout (Argo CD sync wave or a Helm hook);
  - the `rarity` mode in the same binary;
  - an alert on a failed migrate Job.

## How we'll know it was right

Migrate Jobs stay idempotent (a re-run logs `migrations_applied: 0, content_changed: false`), no rollout ever starts pods against an unmigrated schema, and no migration needs editing after it merges.
