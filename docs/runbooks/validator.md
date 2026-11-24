# Runbook: validator not ready, or `validator migrate` fails

- **Alert(s):** none yet; they're [issue 23](https://github.com/levtovhaim/rarebit/issues/23): no ready validator pod, the `/v1/validate` 5xx rate, a failed migrate Job, a lasting normalizer mismatch.
- **Service:** [`catalog/validator.yaml`](../../catalog/validator.yaml)
- **Severity:** page (players' answers can't be checked)
- **Last fired on purpose:** 2026-11-24, locally:
  - Postgres paused under a running validator: `/readyz` → 503 `not_ready`, `/v1/validate` → 503 `unavailable`, both back to 200 after unpausing;
  - a proxy that stopped answering (the integration test): lookups and readiness served again 1.5 s after it recovered.

## What it means

`/readyz` is 503 when one of these holds:
- **draining:** the pod got SIGTERM. Expected during rollouts and node drains. It lasts `VALIDATOR_DRAIN_DELAY` plus up to `VALIDATOR_SHUTDOWN_TIMEOUT`.
- **not ready:** one of these:
  - Postgres didn't answer within 1 s;
  - the schema is older than this image's newest migration;
  - the word lists were never loaded (no successful `validator migrate` against this database).

`validator migrate` exits 1 with a JSON log line `"msg":"migrate failed"` and the cause in `err`.

## Impact on players

With no ready validator pod, the Service has no endpoints. The game should treat every answer as `unknown` and send it to the room vote: rounds still finish, but every answer needs a vote. Nothing is lost, and validation works again as soon as one pod is ready.

## Diagnose (first 5 minutes)

1. Is it every pod or one? Every pod points at Postgres, the schema or the content load. One pod points at that pod (its node, its network).
   ```bash
   kubectl -n <namespace> get pods -l app.kubernetes.io/name=validator
   kubectl -n <namespace> describe pod <pod>      # readiness probe failures in Events
   ```
2. The reason is in the pod's log (JSON): `"msg":"not ready"` with `err`.
   ```bash
   kubectl -n <namespace> logs <pod> --since=10m | grep -E '"level":"(WARN|ERROR)"'
   ```
   - `timeout: context deadline exceeded`, `connection refused`, `no such host`: Postgres is down, overloaded or unreachable. Check the database's own pods, and NetworkPolicies.
   - `relation "schema_migrations" does not exist`: never migrated; see the migrate Job.
   - `the schema is at migration N and this binary needs M`: this image is newer than the schema; the migrate Job for this release didn't run or failed.
   - `no word lists loaded yet`: the schema exists but no content load finished.
3. The migrate Job:
   ```bash
   kubectl -n <namespace> get jobs -l app.kubernetes.io/name=validator
   kubectl -n <namespace> logs job/<migrate-job>
   ```
4. Locally (docker compose or a shell): `curl -s localhost:8080/readyz` and the process's stdout.

A ready pod that logs `the word lists were keyed by another normalizer version` is in a rollout with mixed images. That's expected for its duration; if it lasts, finish or roll back the rollout ([issue 24](https://github.com/levtovhaim/rarebit/issues/24)).

## Fix

Match the error in the log:

| Error | Cause | Fix |
|---|---|---|
| `invalid configuration` | an env var is missing, out of range, or `DATABASE_URL isn't a valid Postgres URL`; the message lists each problem | fix the value in the chart (a PR), or the secret it comes from (SSM, through External Secrets: state-changing, see below) |
| `no category files in <dir>/categories` | `VALIDATOR_DATA_DIR` isn't `/data`, or the image was built without `data/categories/` | fix the value in the chart, or `apps/validator/Dockerfile` / `Dockerfile.dockerignore` and rebuild (a PR), then rerun the Job |
| `exec /validator: no such file or directory` at container start | the binary's dynamic loader or C library is missing: a wrong runtime base image (ADR 0017) | rebuild from the Dockerfile as committed; check that the runtime stage is `distroless/cc` |
| `GLIBCXX_… not found` or `GLIBC_… not found` at container start | the builder's Debian release is newer than the runtime image's | move the builder and the runtime base to the same Debian release (ADR 0017), rebuild |
| `FailedPreStopHook` in the pod's events, or exec probes failing | the image has no shell or tools: an `exec` hook or probe can't run | `httpGet` probes; `lifecycle.preStop.sleep`, or no preStop (apps/validator/README.md → Settings the chart must get right) |
| `<file>.json: ...` | a category file the loader rejects (it reads every file before touching the database) | fix the file in a PR (`python data/tools/check_data.py` shows most problems), then rerun the Job |
| `migration NNNN_x changed after it was applied` | someone edited a merged migration | revert the edit and add a new migration with the change |
| `take the migration lock: ... deadline exceeded` | another run held the lock for the whole 5-minute run limit | find it: `SELECT pid, state, query_start, query FROM pg_stat_activity WHERE application_name = 'rarebit-validator-migrate';` If it's a stuck run, end it with `SELECT pg_terminate_backend(<pid>);` (state-changing), then rerun the Job |
| `lock timeout` during a migration | the DDL waited 5 s for a table lock held by a long transaction | rerun the Job when the long transaction ends; find it in `pg_stat_activity` (`xact_start`) |
| `failed to connect ...` | Postgres is unreachable from the Job | as for "not ready" above |

Rerunning the migrate Job is always safe: applied migrations are skipped, and an unchanged content load does nothing.

**State-changing commands:**
- deleting and recreating a Job (`kubectl delete job <migrate-job>`, then a resync);
- `pg_terminate_backend`;
- changing a secret in SSM.

In a shared environment a human runs them or approves the exact command (CLAUDE.md → Rules, rule 2); in your own preview namespace you may run them yourself.

## Verify

- `curl -s <pod or service>/readyz` → `{"status":"ready"}`;
- a sample answer: `curl -s -X POST <service>/v1/validate -d '{"category":"country","letter":"י","answer":"ישראל"}'` → `"result":"valid"`;
- the migrate Job log ends with `"msg":"migrate done"`, and a rerun shows `"migrations_applied":0,"content_changed":false`.

## Roll back or escalate

- **A bad content load:** revert the data PR; the next migrate run loads the previous files. A category removed by mistake comes back when its file does (retired categories keep their row).
- **A bad migration:** migrations go forward only. Roll the image back (the old code must work with the new schema), then fix it with a new migration.
- **Postgres itself down:** follow the database's runbook. The validator recovers by itself within a couple of seconds of Postgres answering: connection attempts and dials time out after 2 s, and readiness uses a connection of its own.

## Prevention

- `make check` runs the word-list check on every data change, before the loader ever sees it.
- The migrate Job will run before each rollout (ADR 0014, a follow-up with the chart), so new pods never start against an unmigrated schema; readiness also refuses a schema older than the image.
- Alerts with this runbook linked: [issue 23](https://github.com/levtovhaim/rarebit/issues/23).
