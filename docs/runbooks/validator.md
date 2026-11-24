# Runbook: validator not ready, or `validator migrate` fails

- **Alert(s):** none yet. They come with the monitoring stack: `/readyz` failing on every pod, `/v1/validate` 5xx rate, a failed migrate Job.
- **Service:** [`catalog/validator.yaml`](../../catalog/validator.yaml)
- **Severity:** page (players' answers can't be checked)
- **Last fired on purpose:** 2026-11-24, locally: Postgres paused under a running validator, `/readyz` → 503 `not_ready` and `/v1/validate` → 503 `unavailable`; both back to 200 after unpausing.

## What it means

`/readyz` is 503 when one of these holds:
- **draining:** the pod got SIGTERM. Expected during rollouts and node drains, and it lasts `VALIDATOR_DRAIN_DELAY` plus up to `VALIDATOR_SHUTDOWN_TIMEOUT`.
- **not ready:** Postgres didn't answer `SELECT EXISTS (SELECT 1 FROM content_loads)` within 1 s. Either the database is unreachable or slow, or the schema and word lists were never loaded (no successful `validator migrate` against this database).

`validator migrate` exits 1 with a JSON log line `"msg":"migrate failed"` and the cause in `err`.

## Impact on players

With no ready validator pod, the Service has no endpoints. The game should treat every answer as `unknown` and send it to the room vote: rounds still finish, but every answer needs a vote. Nothing is lost; validation works again as soon as one pod is ready.

## Diagnose (first 5 minutes)

1. Is it every pod or one? Every pod points at Postgres or the content load; one pod points at that pod (its node, its network).
   ```bash
   kubectl -n <namespace> get pods -l app.kubernetes.io/name=validator
   kubectl -n <namespace> describe pod <pod>      # readiness probe failures in Events
   ```
2. The reason is in the pod's log (JSON): `"msg":"not ready"` with `err`.
   ```bash
   kubectl -n <namespace> logs <pod> --since=10m | grep -E '"level":"(WARN|ERROR)"'
   ```
   - `timeout: context deadline exceeded`, `connection refused`, `no such host`: Postgres is down, overloaded or unreachable (check the database's own pods, and NetworkPolicies).
   - `relation "content_loads" does not exist`: never migrated; see the migrate Job.
   - `no word lists loaded yet`: the schema exists but no content load finished.
3. The migrate Job:
   ```bash
   kubectl -n <namespace> get jobs -l app.kubernetes.io/name=validator
   kubectl -n <namespace> logs job/<migrate-job>
   ```
4. Locally (docker compose or a shell): `curl -s localhost:8080/readyz` and the process's stdout.

## Fix

Match the error in the log:

| Error | Cause | Fix |
|---|---|---|
| `invalid configuration` | an env var is missing or out of range; the message lists each one | fix the values in the chart or the Secret; nothing starts until then |
| `<file>.json: ...` | a category file the loader rejects (it reads every file before touching the database) | fix the file in a PR (`python data/tools/check_data.py` shows most problems), then rerun the Job |
| `migration NNNN_x changed after it was applied` | someone edited a merged migration | revert the edit and add a new migration with the change |
| `take the migration lock: ... deadline exceeded` | another run held the lock for 5 minutes | find it: `SELECT pid, state, query_start, query FROM pg_stat_activity WHERE application_name = 'rarebit-validator-migrate';` let it finish, or end that run, then rerun |
| `failed to connect ...` | Postgres is unreachable from the Job | as for "not ready" above |

Rerunning the migrate Job is always safe: applied migrations are skipped, and an unchanged content load does nothing. Deleting and recreating a Job is a state-changing command: in a shared environment a human runs it or approves it (CLAUDE.md → Rules, rule 2); in your own preview namespace you may.

## Verify

- `curl -s <pod or service>/readyz` → `{"status":"ready"}`;
- a sample answer: `curl -s -X POST <service>/v1/validate -d '{"category":"country","letter":"י","answer":"ישראל"}'` → `"result":"valid"`;
- the migrate Job log ends with `"msg":"migrate done"`, and a rerun shows `"migrations_applied":0,"content_changed":false`.

## Roll back or escalate

- A bad content load: revert the data PR; the next migrate run loads the previous files.
- A bad migration: migrations go forward only. Roll the image back (the old code must work with the new schema), then fix it with a new migration.
- Postgres itself down: follow the database's runbook. The validator recovers by itself once Postgres answers.

## Prevention

- `make check` runs the word-list check on every data change, before the loader ever sees it.
- The migrate Job runs before each rollout, so new pods never start against an unmigrated schema.
- Alerts with this runbook linked, when the monitoring stack arrives.
