# validator

Checks a player's answer against the word lists in Postgres. It normalizes the answer with [native/hebrew-normalize](../../native/hebrew-normalize/README.md), linked in through cgo, so every component compares answers the same way. One Go binary, three modes:

| Mode | What it does | Runs as |
|---|---|---|
| `validator serve` | The HTTP API and the runtime endpoints | a Deployment |
| `validator migrate` | Applies the schema migrations, then loads `data/categories/*.json` into Postgres | a Job, before each rollout |
| `validator version` | Prints the git SHA | |

Decisions:
- [ADR 0013](../../docs/adr/0013-validator-http-json-api.md): the HTTP/JSON API;
- [ADR 0014](../../docs/adr/0014-migrations-and-content-load-in-the-validator.md): migrations and the content load in this binary, as a Job;
- [ADR 0015](../../docs/adr/0015-validator-lookups-from-postgres.md): lookups straight from Postgres, timeouts, readiness;
- [ADR 0016](../../docs/adr/0016-own-migration-runner.md): the migration runner.

Operating it: [runbook](../../docs/runbooks/validator.md).

## API

`POST /v1/validate` with one answer:

```json
{"category": "country", "letter": "א", "answer": "אוסטריה"}
```

The answer comes back `valid`, `invalid` or `unknown`. The game sends unknown answers to the room vote.

| Result | Extra fields | Example |
|---|---|---|
| `valid` | `match`: `exact`, `variant` (full or defective spelling) or `fuzzy` (a one-letter typo, 4+ letters); `entry`: the word-list entry | אסטריה → `variant`, entry אוסטריה |
| `invalid` | `reason`: `wrong_letter`, `empty` (nothing left after normalizing) or `too_long` | ישראל for the letter ב → `wrong_letter` |
| `unknown` | | not in the list |

Every response carries `key`, the answer's normalized form (empty for `too_long`). The lookup order is the one the library's README prescribes: exact, then variant, then fuzzy among entries with the same first letter and a length within one. That's up to four indexed queries per answer, the category check included.

Errors from `/v1/validate` are JSON, `{"error": "<code>", "message": "..."}`:

| Status | `error` | When |
|---|---|---|
| 400 | `bad_request` | the body isn't `{category, letter, answer}` |
| 400 | `unknown_category` | the category isn't loaded, or isn't a valid id (`^[a-z][a-z0-9_-]{0,63}$`; checked before any query) |
| 400 | `bad_letter` | the letter isn't one of the 22 round letters (final forms never start a word) |
| 413 | `too_large` | the body is over 4 KiB |
| 503 | `unavailable` | Postgres failed or didn't answer within 3 s |

On a 503, or when no validator answers at all, the game should retry once (the call is read-only), then treat the answer as `unknown`. Other paths and methods (a `GET` on `/v1/validate`, say) get Go's plain-text 404 or 405.

## Runtime endpoints

| Endpoint | Meaning |
|---|---|
| `GET /healthz` | Liveness: the process serves HTTP. It never checks Postgres, so a database outage doesn't restart every pod. |
| `GET /readyz` | Readiness, on a connection of its own (not the request pool): 200 when Postgres answers within 1 s, the schema is at least at this binary's newest migration, and the word lists were loaded at least once. 503 while draining, before the first `migrate`, or while Postgres is unreachable. |
| `GET /metrics` | Prometheus: Go and process metrics, plus the ones below |
| `GET /version` | `{"version": "<sha7>", "normalizer": "<library version>", "unicode": "16.0.0", "go": "..."}` |

| Metric | Labels | Use |
|---|---|---|
| `validator_http_requests_total` | `route`, `method`, `code` | error rate per route (a 503 on `/v1/validate` means Postgres) |
| `validator_http_request_duration_seconds` | `route`, `code` | latency |
| `validator_answers_total` | `result`, `detail` (the match or the reason) | the share of `unknown` answers shows thin word lists |
| `validator_draining` | | 1 during shutdown |
| `validator_content_normalizer_mismatch` | | 1 when the loaded keys came from another normalizer version than this binary's: expected briefly during a rollout, a problem if it lasts ([issue 24](https://github.com/levtovhaim/rarebit/issues/24)) |

Logs are JSON on stdout. They never contain the answer text (player input) or the database password.

## Configuration

Environment variables, all checked at startup; the process exits with every problem listed if one is wrong.

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | required | `postgres://user:pass@host:5432/db?sslmode=verify-full`; its format is checked at startup. In Kubernetes it comes from a Secret: `serve` should use a read-only role, `migrate` the owner role (ADR 0014). |
| `VALIDATOR_ADDR` | `:8080` | listen address |
| `VALIDATOR_DATA_DIR` | `/data` | `migrate` only: the directory that holds `categories/` |
| `VALIDATOR_MAX_ANSWER_RUNES` | `64` | longer answers are `invalid`/`too_long` (1–256) |
| `VALIDATOR_FUZZY_CANDIDATES` | `500` | the most entries compared for a typo (1–5000) |
| `DB_MAX_CONNS` | `10` | request pool size per pod (1–100); the readiness check uses one connection more |
| `VALIDATOR_DRAIN_DELAY` | `5s` | how long `/readyz` fails, with keep-alives off, before the server stops accepting connections |
| `VALIDATOR_SHUTDOWN_TIMEOUT` | `20s` | how long in-flight requests get after that |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

Fixed timeouts (ADR 0015): 3 s per validation, 1 s per readiness check, 2 s per new connection or dial. In Postgres: `statement_timeout` 2.5 s and `lock_timeout` 1 s on the request pool.

On SIGTERM the process:
1. fails `/readyz` and turns keep-alives off, so every response closes its connection and clients reconnect to other pods;
2. keeps serving for the drain delay, while the endpoints and the load balancer catch up;
3. stops accepting connections and waits up to the shutdown timeout for requests in flight;
4. closes its database connections (at most 3 s) and exits 0.

A second SIGTERM ends the process at once.

### Settings the chart must get right

- **Grace period:** `terminationGracePeriodSeconds` must be longer than the drain delay + the shutdown timeout + 3 s (28 s with the defaults; Kubernetes' default is 30 s). A `preStop` sleep adds to that: use either a `preStop` sleep or `VALIDATOR_DRAIN_DELAY`, not both.
- **Probes:** the readiness handler takes up to 1 s, so `timeoutSeconds` must be 2 or more (Kubernetes' default of 1 would time out first), with `failureThreshold` 3 or more so one slow check doesn't take a pod out.
- **Connection budget:** (the most pods at once, HPA maximum + `maxSurge`) × (`DB_MAX_CONNS` + 1) + the migrate Job + every other client must stay under Postgres `max_connections` (CloudNativePG default: 100).
- **Migrate connects directly to the primary** (CloudNativePG's `-rw` Service), not through a transaction-mode pooler such as PgBouncer: its advisory lock belongs to the session.

## `validator migrate`

1. Reads and checks every category file, before touching the database.
2. Takes a Postgres advisory lock, so two runs (a retried Job, two rollouts) wait for each other instead of racing. The whole run has 5 minutes; a run still waiting for the lock by then fails.
3. Applies the migrations in `internal/migrate/migrations/` that aren't applied yet, each in its own transaction. A migration edited after it was applied stops the run: add a new one instead. A migration waits at most 5 s for a table lock.
4. Replaces the word lists in one transaction, so `serve` keeps answering from the old lists until it commits. A category whose file was removed is retired, not deleted: it's no longer served, its row stays for the tables that reference it, and restoring the file brings it back. When the files and the normalizer version match the last load, it changes nothing.

Each load is recorded in `content_loads` (time, word count, a SHA-256 over the files, normalizer and Unicode versions). Keys depend on the normalizer, so a new library version reloads everything even if the files didn't change.

If the Job's pod or node disappears mid-run, Postgres ends its session within about 30 s (idle timeouts, TCP keepalives), which frees the lock for the next run.

## Build and test

cgo needs a C compiler and the library's archive. The validator builds on Linux; macOS should work (it links `libc++` there) but isn't verified yet; on Windows, build in WSL or in the image. `make validator-integration` also needs Docker.

```bash
make validator               # builds the library into native/build/hn-prefix, then go vet, go test -race, go build
make validator-integration   # the same tests plus the Postgres ones, against a throwaway postgres:18.7 container
```

The Postgres tests cover the migrate run, its lock and its checksums, every kind of lookup, retiring and restoring a category, and recovery after a database stall: a proxy that accepts connections and never answers, then forwards again.

The binary is `apps/validator/build/validator`. It links the C++ library statically and, on Linux, the C++ runtime (`libstdc++`) dynamically. Set the version at build time with `-ldflags "-X main.version=<sha7>"`; without it, the binary reports the SHA the Go toolchain recorded, or `unknown`.

Run it locally against a database:

```bash
export DATABASE_URL='postgres://postgres:<password>@127.0.0.1:5432/postgres?sslmode=disable' VALIDATOR_DATA_DIR=data
apps/validator/build/validator migrate
apps/validator/build/validator serve
curl -s -X POST localhost:8080/v1/validate -d '{"category":"country","letter":"י","answer":"ישראל"}'
```
