# Architecture

Components and data flow. The **Status** column says what exists today; everything else is the design the code is being built toward. See [CLAUDE.md](../CLAUDE.md) for the rules every component follows, and [docs/adr/](adr/) for why each choice was made.

## Components

| Component | Technology | Role | Status |
|---|---|---|---|
| `native/hebrew-normalize` | C++20 static library, C API | Normalizes answers and matches them against word-list entries ([README](../native/hebrew-normalize/README.md), ADRs 0008–0011) | built |
| `apps/validator` | Go, cgo | Checks an answer against the word lists in Postgres, using `hebrew-normalize`: `POST /v1/validate`, HTTP/JSON ([README](../apps/validator/README.md), ADR 0013). The same binary runs the `migrate` job (schema migrations and the word-list load, ADRs 0014 and 0016) and later the `rarity` job. Image: distroless, built and smoke-tested locally (ADR 0017). | built (image not in a registry yet) |
| `apps/game` | Node.js, TypeScript, Socket.IO | Server-authoritative rounds. All room and matchmaking state is in Redis, so any pod can serve any room. | planned |
| `apps/web` | React, Vite | Hebrew (RTL) UI for phones, served as static files by nginx-unprivileged; supports `BASE_PATH` | planned |
| `apps/bots` | TypeScript | Simulated players: load tests, synthetic monitoring (a full game, exit 0 or 1), chaos observation, and the test arena's personas and bot swarm | planned |
| `apps/content-agents` | scheduled agents | The answer curator and the category creator: they propose content changes as PRs to `data/` and never write to the database | planned |
| `data/` | JSON files in git | Word lists and categories, changed only by PR ([README](../data/README.md), ADR 0012). Seeded with the six regular categories. | seeded |
| `native/rarebit-cli` | C++ (CMake) | Word check and a local bots runner on Linux, Windows and macOS | planned |
| Redis | | Room and matchmaking state, Socket.IO fan-out between game pods, the answer-event stream | planned |
| Postgres | 18 | Word lists (schema in `apps/validator`, tested against a local container), answer history, the rarity table | schema for word lists |

## Request path

```
phone ──HTTPS──> web (static files)
phone ──WebSocket──> game ──> validator ──> Postgres (word lists)
                      │           └─ hebrew-normalize (linked in, cgo)
                      └──> Redis (room state, fan-out between game pods)
```

- **Game ↔ phones:** Socket.IO uses the WebSocket transport only. Since every pod reads room state from Redis, no sticky sessions are needed.
- **Validator:** one HTTP call per answer. It normalizes the answer once, looks for an exact key match first, then a spelling variant or a one-edit typo among a few candidates ([hebrew-normalize](../native/hebrew-normalize/README.md)), with up to four indexed Postgres queries (ADR 0015). If it can't answer (503, or no ready pod), the game sends the answer to the room vote, as it does for `unknown` answers.

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
- graceful drain on SIGTERM;
- non-root with a read-only root filesystem.
