# 0016. Apply migrations with a small runner in the validator, not a migration tool

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

`validator migrate` applies the schema migrations before the content load (ADR 0014). It needs to apply them in order exactly once, survive concurrent and retried runs, and notice when someone edits a migration that's already applied. The schema is small: one migration today.

## Decision

- Migrations are plain SQL files embedded in the binary, `internal/migrate/migrations/NNNN_name.sql`, numbered 1, 2, 3, ... without gaps.
- Each one is applied in its own transaction, together with its row in `schema_migrations` (version, name, SHA-256 of the file).
- A run holds a session-level Postgres advisory lock, so a second run waits for it.
- An applied migration whose file changed stops the run. The fix is a new migration.
- **Forward only.** A rollback deploys an older image that must still work with the newer schema: changes go expand, then contract, across releases. A database newer than the binary is logged as a warning, not an error, so rollbacks work.

## Alternatives considered

| Option | Why not |
|---|---|
| golang-migrate or goose | Another dependency and CLI to replace about 100 lines. Their down migrations don't help: a rollback here is an older image, not a reversed schema. |
| Atlas (declarative schema, diff-based plans) | Worth a second look if the schema grows; for a handful of tables it adds a tool, its state and its own review flow. |
| Flyway or Liquibase | A JVM in the image, or a second image, for the same job. |

## Consequences

- **Good:**
  - no extra dependency in the image;
  - the migrations ship inside the binary they belong to, so they can't drift apart;
  - checksums catch edited migrations.
- **Bad / risks:**
  - every migration runs inside a transaction, so `CREATE INDEX CONCURRENTLY` (which can't) needs another path when a table grows large;
  - no drift detection against a hand-modified database;
  - expand/contract discipline rests on review.

## How we'll know it was right

Migrations stay simple SQL that reviews well. If the schema grows past a dozen tables, or we need concurrent index builds or drift detection, move to Atlas with a new ADR.
