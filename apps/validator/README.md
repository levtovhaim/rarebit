# validator

Checks a player's answer against the word lists in Postgres. It normalizes the answer with [native/hebrew-normalize](../../native/hebrew-normalize/README.md), linked in through cgo, so every component compares answers the same way. One Go binary, three modes:

| Mode | What it does | Runs as |
|---|---|---|
| `validator serve` | The HTTP API and the runtime endpoints | a Deployment |
| `validator migrate` | Applies the schema migrations, then loads `data/categories/*.json` into Postgres | a Job, before each rollout |
| `validator version` | Prints the git SHA | |

Decisions: [ADR 0013](../../docs/adr/0013-validator-http-json-api.md) (the API, lookups straight from Postgres) and [ADR 0014](../../docs/adr/0014-migrations-and-content-load-in-the-validator.md) (migrations and the content load). Operating it: [runbook](../../docs/runbooks/validator.md).

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

Every response carries `key`, the answer's normalized form. The lookup order (exact, then variant, then fuzzy among entries with the same first letter and a length within one) is the one the library's README prescribes.

Errors are JSON, `{"error": "<code>", "message": "..."}`:

| Status | `error` | When |
|---|---|---|
| 400 | `bad_request` | the body isn't `{category, letter, answer}` |
| 400 | `unknown_category` | the category isn't loaded |
| 400 | `bad_letter` | the letter isn't one of the 22 round letters (final forms never start a word) |
| 413 | `too_large` | the body is over 4 KiB |
| 503 | `unavailable` | Postgres failed or didn't answer within 3 s; the game should treat the answer as `unknown` |

## Runtime endpoints

| Endpoint | Meaning |
|---|---|
| `GET /healthz` | Liveness: the process serves HTTP. It never checks Postgres, so a database outage doesn't restart every pod. |
| `GET /readyz` | Readiness: 200 when Postgres answers within 1 s and the word lists were loaded at least once; 503 while draining, before the first `migrate`, or while Postgres is unreachable. |
| `GET /metrics` | Prometheus: Go and process metrics, plus the ones below |
| `GET /version` | `{"version": "<sha7>", "normalizer": "<library version>", "unicode": "16.0.0", "go": "..."}` |

| Metric | Labels | Use |
|---|---|---|
| `validator_http_requests_total` | `route`, `method`, `code` | error rate per route (a 503 on `/v1/validate` means Postgres) |
| `validator_http_request_duration_seconds` | `route`, `code` | latency |
| `validator_answers_total` | `result`, `detail` (the match or the reason) | the share of `unknown` answers shows thin word lists |
| `validator_draining` | | 1 during shutdown |

Logs are JSON on stdout. They never contain the answer text (player input) or the database password.

## Configuration

Environment variables, all checked at startup; the process exits with every problem listed if one is wrong.

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | required | `postgres://user:pass@host:5432/db?sslmode=...`; in Kubernetes it comes from a Secret |
| `VALIDATOR_ADDR` | `:8080` | listen address |
| `VALIDATOR_DATA_DIR` | `/data` | `migrate` only: the directory that holds `categories/` |
| `VALIDATOR_MAX_ANSWER_RUNES` | `64` | longer answers are `invalid`/`too_long` (1–256) |
| `VALIDATOR_FUZZY_CANDIDATES` | `500` | the most entries compared for a typo (1–5000) |
| `DB_MAX_CONNS` | `10` | pool size per pod (1–100): pods × this must stay under Postgres `max_connections` |
| `VALIDATOR_DRAIN_DELAY` | `5s` | how long `/readyz` fails before the server stops accepting connections |
| `VALIDATOR_SHUTDOWN_TIMEOUT` | `20s` | how long in-flight requests get after that |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

On SIGTERM the process fails `/readyz`, keeps serving for the drain delay while the endpoints and the load balancer catch up, then stops accepting connections and waits up to the shutdown timeout. So the pod's `terminationGracePeriodSeconds` must be longer than the drain delay plus the shutdown timeout (25 s with the defaults; Kubernetes' default grace period is 30 s). A second SIGTERM ends the process at once.

## `validator migrate`

1. Reads and checks every category file, before touching the database.
2. Takes a Postgres advisory lock, so two runs (a retried Job, two rollouts) wait for each other instead of racing.
3. Applies the migrations in `internal/migrate/migrations/` that aren't applied yet, each in its own transaction. A migration edited after it was applied stops the run: add a new one instead.
4. Replaces the word lists in one transaction, so `serve` keeps answering from the old lists until it commits. A category whose file was removed is deleted. When the files and the normalizer version match the last load, it changes nothing.

Each load is recorded in `content_loads` (time, word count, a SHA-256 over the files, normalizer and Unicode versions). Keys depend on the normalizer, so a new library version reloads everything even if the files didn't change.

## Build and test

cgo needs a C compiler and the library's archive, so the validator builds on Linux and macOS (on Windows, in WSL or in the image).

```bash
make validator               # builds the library into native/build/hn-prefix, then go vet, go test -race, go build
make validator-integration   # the same tests plus the Postgres ones, against a throwaway postgres:18.7 container
```

The binary is `apps/validator/build/validator`. It links the C++ library statically and the C++ runtime (`libstdc++`) dynamically. Set the version at build time with `-ldflags "-X main.version=<sha7>"`; without it, the binary reports the SHA the Go toolchain recorded, or `unknown`.

Run it locally against a database:

```bash
export DATABASE_URL='postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable' VALIDATOR_DATA_DIR=data
apps/validator/build/validator migrate
apps/validator/build/validator serve
curl -s -X POST localhost:8080/v1/validate -d '{"category":"country","letter":"י","answer":"ישראל"}'
```
