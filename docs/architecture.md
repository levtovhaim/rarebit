# Architecture

Components and data flow. The **Status** column says what exists today; everything else is the design the code is being built toward. See [CLAUDE.md](../CLAUDE.md) for the rules every component follows, and [docs/adr/](adr/) for why each choice was made.

## Components

| Component | Technology | Role | Status |
|---|---|---|---|
| `native/hebrew-normalize` | C++20 static library, C API | Normalizes answers and matches them against word-list entries ([README](../native/hebrew-normalize/README.md), ADRs 0008, 0009) | built |
| `apps/validator` | Go, cgo | HTTP service that checks an answer against the word lists in Postgres, using `hebrew-normalize`. The same image runs the `migrate` and `rarity` jobs. | planned |
| `apps/game` | Node.js, TypeScript, Socket.IO | Server-authoritative rounds. All room and matchmaking state is in Redis, so any pod can serve any room. | planned |
| `apps/web` | React, Vite | Hebrew (RTL) UI for phones, served as static files by nginx-unprivileged; supports `BASE_PATH` | planned |
| `apps/bots` | TypeScript | Simulated players: a full synthetic game, load tests, chaos observation | planned |
| `native/rarebit-cli` | to be decided (ADR) | Word check and a local bots runner on Linux, Windows and macOS | planned |
| Redis | | Room and matchmaking state, Socket.IO fan-out between game pods, the answer-event stream | planned |
| Postgres | | Word lists, answer history, the rarity table | planned |

## Request path

```
phone ──HTTPS──> web (static files)
phone ──WebSocket──> game ──HTTP──> validator ──> Postgres (word lists)
                      │                 └─ hebrew-normalize (linked in, cgo)
                      └──> Redis (room state, fan-out between game pods)
```

- **Game ↔ phones:** Socket.IO uses the WebSocket transport only. Since every pod reads room state from Redis, no sticky sessions are needed.
- **Validator:** one call per answer. It looks for an exact match against all entries first, then a spelling variant or a one-edit typo ([hebrew-normalize](../native/hebrew-normalize/README.md)).

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
