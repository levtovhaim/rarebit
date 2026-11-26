# game

The game server: rooms, rounds, validation, the vote and scoring, over Socket.IO (WebSocket only). Rounds are server-authoritative, and **all state is in Redis**, so any pod can serve any room and a round goes on when the pod that started it goes away. Node.js 26 + TypeScript.

Decisions:
- [ADR 0019](../../docs/adr/0019-game-state-in-redis.md): room state and matchmaking in Redis;
- [ADR 0020](../../docs/adr/0020-game-client-protocol.md): the client protocol;
- [ADR 0021](../../docs/adr/0021-game-timers-swept-with-leases.md): the timers, swept by every pod under leases.

Operating it: [runbook](../../docs/runbooks/game.md).

## The game

- **Private rooms:** 2–8 players, a 6-character code (no 0/O/1/I/L), and a host who starts the game.
- **Quick play:** players join the open public room. It starts after a `QUICKPLAY_COUNTDOWN_SECONDS` countdown once `QUICKPLAY_MIN_PLAYERS` are connected, or at once when 8 have joined. The countdown stops if too few stay connected. The same nickname twice in one public room becomes "דני 2".
- **Rounds:** each round picks a category, then a letter with at least 3 entries in that category (from the validator's `GET /v1/categories`), not repeating a pair within a game. Players have `ROUND_SECONDS` to answer.
  - If no pod can get the categories (the validator down and nothing cached), the room waits and retries after 2, 4, 8, then every 10 seconds; its state shows `notice: "waiting_for_categories"`.
- **Validation:** answers that are empty or blocked by the offensive-word filter are invalid; a blocked answer's text is never shown to the other players. The validator checks the others: `valid`, `invalid` or `unknown`.
  - Unknown answers go to a `VOTE_SECONDS` room vote; a majority of the votes cast accepts, and a tie or no votes rejects. The author doesn't vote on their own answer.
  - When the validator can't give a verdict (no answer within 3.5 s, a connection error or a 503, each retried once; any other error), the answer counts as unknown too.
- **Scoring:**
  - valid and unique in the room: 10; valid and shared (same comparison key): 5;
  - plus a rarity bonus of 0–5 (0 until the rarity table exists);
  - anything not valid is a strike, and `MAX_STRIKES` eliminates a player, who keeps their points.
- **End:** after `MAX_ROUNDS`, or when one player is left in the game. The highest total wins, eliminated or not. Ties go to fewer strikes, then it's a shared win.

## Protocol

Clients connect with `transports: ["websocket"]` to `SOCKET_PATH` (default `/socket.io`). Every client event needs an acknowledgement callback, and gets `{ ok: true, ... }` or `{ ok: false, error: "<code>" }`.

| Client → server | Payload | Reply (besides `ok`) |
|---|---|---|
| `room:create` | `{ nickname }` | `roomCode, playerId, token, state` |
| `room:join` | `{ roomCode, nickname }` | the same |
| `quickplay:join` | `{ nickname }` | the same |
| `room:resume` | `{ roomCode, playerId, token }` | `token, state`: after a reconnect, on any pod. The token is new; the old one stops working. |
| `game:start` | `{}` | host only, private rooms, 2+ players |
| `answer:submit` | `{ round, answer }` | can be resent until the deadline; the last one counts |
| `vote:cast` | `{ round, playerId, accept }` | `playerId` is the answer's author |
| `room:leave` | `{}` | before the game the player is gone; during it they're out, keeping their points |
| `room:sync` | `{}` | `state`, for a client that suspects it missed an event |

| Server → client | Payload |
|---|---|
| `room:state` | the room snapshot, after every change: players, scores, phase, `deadline`, `serverNow`, `notice`, the last results |
| `round:start` | `{ round, letter, category: { id, name }, deadline, serverNow }` |
| `vote:start` | `{ round, items: [{ playerId, nickname, answer }], deadline, serverNow }` |
| `round:results` | `{ round, letter, category, answers: [{ playerId, nickname, answer, verdict, final, points, strike }], standings, serverNow }` |
| `game:end` | `{ winners: [playerId], standings }` |
| `server:draining` | `{}`: reconnect (to another pod) and send `room:resume` |

Deadlines are epoch milliseconds on the server's clock (Redis's). A client shows `deadline - serverNow` from the moment the event arrived, so a skewed phone clock doesn't matter.

What a client must do:
- **Watchdog:** if a deadline has passed by 1.5 s and no new `room:state` came, send `room:sync`.
- **Reconnect jitter:** after `server:draining` or a dropped connection, wait a random 0–2 s before reconnecting.
- **Keep the newest token:** every `room:resume` returns a new one.
- **One seat per connection:** joining or creating another room leaves the room the connection was in. Opening the same seat in a second tab closes the first.

Limits:
- a frame is at most 16 KiB; a nickname at most 64 characters as sent (2–16 after cleaning), an answer 256 as sent (64 kept);
- 10 events in a burst, then 5 a second, per connection;
- after 5 joins or resumes refused with `not_found` or `bad_token`, the server closes the connection;
- each pod accepts `MAX_CONNECTIONS_PER_IP` connections per client address; more fail to connect with `too_many_connections`.

Error codes:
- **requests:** `bad_request`, `rate_limited`;
- **nicknames:** `bad_nickname` (2–16 Hebrew or Latin letters, digits, spaces, `-`, `_`, `'`), `nickname_blocked`, `nickname_taken`;
- **joining:** `not_found`, `room_full`, `already_started`, `bad_token`, `not_in_room`;
- **game actions:** `not_host`, `not_enough_players`, `not_allowed`, `not_accepting`, `too_late`, `not_playing`, `not_voting`;
- **the server:** `draining` (reconnect elsewhere), `busy` (too many concurrent changes to one room: retry), `unavailable` (Redis failed: retry).

## Runtime endpoints

| Endpoint | Meaning |
|---|---|
| `GET /healthz` | Liveness: the process serves HTTP. It never checks Redis. |
| `GET /readyz` | 200 when all three Redis connections are up and a write succeeds within 1 s (a write also fails on a read-only replica after a failover); 503 while draining or otherwise. New WebSocket connections are refused while it isn't ready. |
| `GET /metrics` | Prometheus |
| `GET /version` | `{ "version": "<sha7>", "node": "v26..." }` |

| Metric | Labels | Meaning |
|---|---|---|
| `game_rooms_active` | `type` | rooms with activity within the room TTL, read from Redis (the same on every pod) |
| `game_players_connected` | | sockets on this pod (sum across pods) |
| `game_rounds_total` | | rounds finished |
| `game_answers_total` | `result` | `valid`, `invalid`, `empty`, `blocked`, `accepted`, `rejected` (unknown answers after the vote) |
| `game_answer_ack_seconds` | | from receiving an answer to acknowledging it |
| `game_validation_seconds` | | validator calls, retry included |
| `game_matchmaking_wait_seconds` | | quick play: from joining to the game starting |
| `game_matchmaking_queue_length` | | players in the open quick-play room |
| `game_filter_blocked_total` | `field` | `nickname` or `answer` |
| `game_ws_disconnects_total` | `reason` | Socket.IO's disconnect reasons |
| `game_redis_errors_total` | | Redis client errors and failed Redis operations |
| `game_rate_limited_total` | | events refused by the rate limit |
| `game_connections_refused_total` | `reason` | WebSocket connections refused: `not_ready` (starting, draining or without Redis), `origin` (not in `ALLOWED_ORIGINS`), `per_ip` (over `MAX_CONNECTIONS_PER_IP`) |
| `game_draining` | | 1 during shutdown |

The Node.js defaults come too, event-loop lag (`nodejs_eventloop_lag_seconds`) included. Logs are JSON on stdout, with `room_id` and `round`, and never contain answers or tokens.

## Configuration

Environment variables, checked at startup; the process exits listing every problem if one is wrong (never their values: URLs can hold passwords).

| Variable | Default | Notes |
|---|---|---|
| `REDIS_URL` | required | `redis://` or `rediss://`; one Redis, not Redis Cluster (ADR 0019) |
| `VALIDATOR_URL` | required | the validator's base URL, e.g. `http://validator:8080` |
| `ALLOWED_ORIGINS` | required | origins allowed to open a WebSocket, comma-separated, exactly as browsers send them (`https://rarebit.example`, no path or trailing slash); `*` allows any (local development only) |
| `GAME_PORT` | `8080` | HTTP and WebSocket, 1–65535 |
| `SOCKET_PATH` | `/socket.io` | change it for path-based previews |
| `ROUND_SECONDS` | `20` | 3–120 |
| `VOTE_SECONDS` | `5` | 2–60 |
| `RESULTS_SECONDS` | `5` | the pause after a round's results, 1–60 |
| `MAX_ROUNDS` | `10` | 1–30 |
| `MAX_STRIKES` | `3` | 1–10 |
| `QUICKPLAY_MIN_PLAYERS` | `3` | 2–8 |
| `QUICKPLAY_COUNTDOWN_SECONDS` | `15` | 0–120 |
| `ROOM_TTL_SECONDS` | `7200` | 300–86400: a game's keys expire this long after its last change |
| `LOBBY_TTL_SECONDS` | `600` | 60–86400: the same for a room that hasn't started, or has ended |
| `MAX_CONNECTIONS_PER_IP` | `20` | 1–10000, per pod |
| `TRUSTED_PROXY_HOPS` | required | 0–5: how many proxies in front of the pod append to `X-Forwarded-For`: behind the ALB 1, behind the local stack's nginx 1, connected directly 0 (the peer address counts). No default: a wrong value behind a load balancer counts every player as the load balancer's address, and `MAX_CONNECTIONS_PER_IP` then refuses all but a few dozen per pod. |
| `DRAIN_DELAY_SECONDS` | `15` | 0–60: how long readiness fails before players are told to reconnect |
| `SHUTDOWN_TIMEOUT_SECONDS` | `10` | 1–300: after that and the 1 s for clients to hear `server:draining`, the process gives up waiting and exits 1 |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `GIT_SHA` | `unknown` | what `/version` reports; the image sets it |

## State in Redis

All keys start with `rb:`, with no per-environment prefix (environments get a Redis, or a database number, each); `src/store.ts` lists them.
- **A room:** one JSON value, changed only by a compare-and-set script. The same script moves the room's entry in the `rb:deadlines` sorted set, so a crash can't leave a room without its timer.
- **Answers, votes and resume-token hashes:** small hashes beside it. Answers and votes are checked and written in one script, against Redis's clock.
- **Timers:** every pod sweeps `rb:deadlines` every 200 ms. It takes a 15 s lease on a due room, advances it only if the room is still in the state it read, then puts the room's entry back at its real deadline or removes it. A transition happens once even when two pods race, and an entry for a room that's gone is removed by the first sweep that reaches it. The sweep needs only the command connection: with pub/sub down, a pod still advances rooms (its own players get the events; the others catch up with `room:sync`).
- **Answer events:** every scored answer goes to the stream `rb:answers` (trimmed near 100,000 entries) for the data pipeline.
- **Memory:** a room's keys expire `LOBBY_TTL_SECONDS` after its last change before the game starts and after it ends, `ROOM_TTL_SECONDS` during it; plus the stream.

The Redis it runs on must use `maxmemory-policy noeviction`: an evicted room key ends a game. Without persistence, a Redis restart ends every running game (players get `not_found` on resume).

## Shutdown

On SIGTERM:
1. Readiness fails, new players are refused (`draining`), and this pod stops advancing rooms (the others take over).
2. It keeps serving connected players for `DRAIN_DELAY_SECONDS`, long enough for the readiness probe to fail and the load balancer to stop sending new connections. Rooms it was advancing finish meanwhile, or are left to other pods after 2 s.
3. It sends `server:draining`; clients reconnect, and resume on another pod from Redis.
4. A second later it closes the sockets and Redis, and exits 0. A second SIGTERM exits at once; if closing takes longer than `SHUTDOWN_TIMEOUT_SECONDS`, it exits 1.

The pod's `terminationGracePeriodSeconds` must exceed `DRAIN_DELAY_SECONDS + 1 + SHUTDOWN_TIMEOUT_SECONDS` (26 s with the defaults; 30 leaves a margin), so the process ends on its own before the kubelet's SIGKILL. WebSocket connections idle for longer than the load balancer's idle timeout are kept alive by Socket.IO's 10 s pings.

## Build and test

```bash
make game              # npm ci (scripts disabled), tsc type check, unit tests, build to dist/
make game-integration  # the Redis tests, against a throwaway redis:8.10.3-alpine container (Docker)
make game-image        # the container image (apps/game/Dockerfile), tagged rarebit-game:dev
make game-image-smoke  # the image, non-root and read-only, against a throwaway Redis (needs make game first)
```

The unit tests cover:
- the rules (scoring, strikes, elimination, the end, winners, ties, the vote, picking rounds, nicknames);
- the filter;
- config (origins included);
- the validator client against a fake HTTP server: retries, a 503, a validator that never answers, a body that isn't JSON; the categories cache, its fallback, an empty list, one request for many callers, no new request for 5 s after a failure.

The Redis tests run game servers in one process as pods:
- a whole game with the players on different pods;
- a pod shut down mid-round while the other finishes the round;
- the vote;
- quick play across pods;
- the drain;
- leftover deadline entries (more than a sweep's batch) that would otherwise block every room;
- Redis dropping every connection mid-round;
- the publishing connection down and refused for a while: broadcasts fail without crashing, the round still starts, readiness fails until it's back;
- an answer just before the deadline counts, one just after gets `too_late`;
- a blocked answer's text in no result, state or stream entry;
- one seat per connection; a new token on resume, and the older connection closed across pods;
- the failed-join limit and the per-address connection limit;
- the lobby and game TTLs;
- origins, offensive nicknames, and the metrics.

The cross-pod test fails without the Redis adapter (checked).

The image smoke test checks the image's contract (below), then, against a throwaway Redis: a bad config exits 1 without printing values; `/readyz`, `/healthz`, `/version` (matching the image's revision label) and `/metrics`; a room created and read back over Socket.IO (`test/smoke-client.ts`); `check-ready` inside the container; one process, `node` itself; and a SIGTERM drain that exits 0.

Run it locally: `npm run build && REDIS_URL=redis://127.0.0.1:6379 VALIDATOR_URL=http://127.0.0.1:8080 ALLOWED_ORIGINS='*' TRUSTED_PROXY_HOPS=0 npm start` in `apps/game`, or the image (`make game-image`) with the same variables. The whole stack, two replicas behind nginx included, runs with `make up` ([compose/](../../compose/README.md)).

## Image

[`Dockerfile`](Dockerfile) ([ADR 0022](../../docs/adr/0022-game-image-distroless-nodejs.md)): built on `node:26.13.1-trixie-slim` (`npm ci`, `tsc`, `npm prune --omit=dev`), run on `gcr.io/distroless/nodejs26-debian13:nonroot`. Both are pinned by digest. The build context is the repo root, limited to the six paths in [`Dockerfile.dockerignore`](Dockerfile.dockerignore).

The contract, checked by `make game-image-smoke`:
- user `65532:65532` (numeric), a read-only root filesystem, no capabilities needed; no shell, no npm;
- `ENTRYPOINT ["/nodejs/bin/node", "/app/dist/main.js"]`: Node is PID 1 and gets SIGTERM itself. Kubernetes `args:` are passed to the server; replacing it takes `command:`;
- `/version` reports the `GIT_SHA` build arg (`make game-image` passes the commit, with `-dirty` for uncommitted changes);
- the built server and its production dependencies only; nothing world-writable, setuid or setgid;
- at most 230 MB unpacked (it's about 201 MB, 150 MB of which is the Node binary).

Settings the deployment must get right:
- **Probes:** `httpGet` on `/healthz` (liveness) and `/readyz` (readiness), with `timeoutSeconds: 2` or more on readiness: `/readyz` waits up to 1 s for its Redis write, and the kubelet's default timeout is 1 s. The image has no shell, so `exec` probes and `preStop` hooks that run a shell can't work.
- **`TRUSTED_PROXY_HOPS: 1`** behind the ALB, so `MAX_CONNECTIONS_PER_IP` counts players, not the ALB's addresses. `game_connections_refused_total{reason="per_ip"}` rising means the cap or the hops are wrong.
- **Command health checks** (docker compose): `["/nodejs/bin/node", "/app/dist/check-ready.js"]`, which exits 0 when `/readyz` answers 200 within 2 s.
- **`terminationGracePeriodSeconds`:** more than `DRAIN_DELAY_SECONDS + 1 + SHUTDOWN_TIMEOUT_SECONDS` (Shutdown, above).
- **Stack traces in source:** the logs carry error messages, not stacks. To map Node's own stack traces back to the TypeScript, set `NODE_OPTIONS=--enable-source-maps`; the source maps are in the image.
