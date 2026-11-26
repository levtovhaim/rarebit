# Architecture

Components and data flow. The **Status** column says what exists today; everything else is the design the code is being built toward. See [CLAUDE.md](../CLAUDE.md) for the rules every component follows, and [docs/adr/](adr/) for why each choice was made.

## Components

| Component | Technology | Role | Status |
|---|---|---|---|
| `native/hebrew-normalize` | C++20 static library, C API | Normalizes answers and matches them against word-list entries ([README](../native/hebrew-normalize/README.md), ADRs 0008–0011) | built |
| `apps/validator` | Go, cgo | Checks an answer against the word lists in Postgres, using `hebrew-normalize`: `POST /v1/validate`, and `GET /v1/categories` for the letters each category can play, HTTP/JSON ([README](../apps/validator/README.md), ADR 0013). The same binary runs the `migrate` job (schema migrations and the word-list load, ADRs 0014 and 0016) and later the `rarity` job. Image: distroless, built and smoke-tested locally (ADR 0017). | built (image not in a registry yet) |
| `apps/game` | Node.js, TypeScript, Socket.IO | Server-authoritative rounds. All room, timer and matchmaking state is in Redis, so any pod can serve any room and finish a round another pod started ([README](../apps/game/README.md), ADRs 0019–0021). Image: distroless Node.js, built and smoke-tested locally (ADR 0022). | built (image not in a registry yet) |
| `apps/web` | React, Vite | Hebrew (RTL) UI for phones, built to static files that work under any path prefix (relative asset URLs, the prefix read from the page's own URL; no `BASE_PATH` setting); every screen renders from the room snapshot the game pushes, and the player resumes after a reload or a drain ([README](../apps/web/README.md), ADR 0026). Image: nginx-unprivileged serving the build under any prefix on 8080, `/metrics` on 9113, the rest of the runtime contract in nginx (ADR 0027); hashed assets cached for a year, the page revalidated (ADR 0028); a strict CSP (ADR 0029); built and smoke-tested locally. | built (image not in a registry yet) |
| `apps/bots` | TypeScript, `socket.io-client` | Simulated players that are full protocol clients: the synthetic game (exit 0 or 1), load tests and the chaos observer, judged by failed games; a strategy hook for the test arena's personas ([README](../apps/bots/README.md), ADR 0023). Image: distroless Node.js, built and smoke-tested locally (ADR 0025). Later the bot swarm. | built (image not in a registry yet) |
| `apps/content-agents` | scheduled agents | The answer curator and the category creator: they propose content changes as PRs to `data/` and never write to the database | planned |
| `data/` | JSON files in git | Word lists and categories, changed only by PR ([README](../data/README.md), ADR 0012). Seeded with the six regular categories. | seeded |
| `native/rarebit-cli` | C++ (CMake) | For developers and operators: judges an answer offline from `data/categories` with the validator's rules (a parity test checks they agree), shows normalization keys, and runs the bots image with docker ([README](../native/rarebit-cli/README.md), ADR 0030). Linux build verified; Windows and macOS with the CI matrix. | built (no releases yet) |
| Redis | 8.10 | Room, timer and matchmaking state, Socket.IO fan-out between game pods, the answer-event stream (keys in `apps/game/src/store.ts`, tested against a local container) | used by the game |
| Postgres | 18 | Word lists (schema in `apps/validator`, tested against a local container), answer history, the rarity table | schema for word lists |
| `infra/` | Terraform modules, Terragrunt | The AWS account as code: plain modules applied by a thin Terragrunt layer, one state file per unit ([README](../infra/README.md), ADR 0033). So far, the S3 bucket that holds every unit's state, locked with S3 lockfiles (ADR 0032). | written (not applied yet) |

## Request path

```
phone ──HTTPS──> web (static files; the socket path follows the page's path)
phone ──WebSocket──> game ──> validator ──> Postgres (word lists)
                      │           └─ hebrew-normalize (linked in, cgo)
                      └──> Redis (room state, fan-out between game pods)
```

- **Game ↔ phones:** Socket.IO uses the WebSocket transport only. Since every pod reads room state from Redis, no sticky sessions are needed. Every pod sweeps the rooms' deadlines in Redis and advances the ones it gets a lease for, so rounds go on when a pod dies; players resume on another pod with their token (ADRs 0019–0021).
- **Game → validator:** at the end of a round, one call per answer, and the playable categories (`GET /v1/categories`, cached for a minute and shared between game pods through Redis) before each round.
- **Validator:** one HTTP call per answer. It normalizes the answer once, looks for an exact key match first, then a spelling variant or a one-edit typo among a few candidates ([hebrew-normalize](../native/hebrew-normalize/README.md)), with up to four indexed Postgres queries (ADR 0015). If it can't answer (503, or no ready pod), the game sends the answer to the room vote, as it does for `unknown` answers.

## Local stack

`make up` runs all of it on one machine with docker compose ([compose/](../compose/README.md), ADR 0024): nginx on `127.0.0.1:8080` in front of the web UI's container (`/`) and two game replicas (`/socket.io/`, round robin, no sticky sessions), Redis, the validator, Postgres, and the `migrate` job that loads the word lists. Startup is gated on health: the validator waits for `migrate` to finish, the game for Redis. `make smoke` runs the bots image, which plays a game through nginx (ADR 0025).

## Content changes

```
content agents / contributors ──PR──> data/ ──> data CI ──> preview ──> review ──> merge ──> validator image build ──> validator migrate Job ──> Postgres
```

Word lists and categories change only by pull request; the `validator migrate` Job is the only writer of content into the database. It computes each entry's keys with the same library `serve` uses on answers, and replaces the lists in one transaction (ADR 0014). The lists ship inside the validator image, so a content change is a new image, rolled out like a code change (ADR 0018).

## Data pipeline

```
game ──> Redis Stream (answer events) ──> ingest ──> Postgres (answers, partitioned by month)
                                                       └─> rarity job ──> rarity table ──> game (cached)
```

Rarer valid answers score more. The rarity table comes from every game's answer history.

## Every service

The runtime contract is in [CLAUDE.md](../CLAUDE.md) → Rules, rule 7:
- `/healthz`, `/readyz` (false while draining), `/metrics`, `/version`;
- JSON logs to stdout;
- config from environment variables, validated at startup;
- graceful drain on the image's stop signal (SIGTERM, or SIGQUIT for nginx);
- non-root with a read-only root filesystem.
