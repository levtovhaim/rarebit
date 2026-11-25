# game

The game server: rooms, rounds, validation, the vote and scoring, over Socket.IO (WebSocket only). Rounds are server-authoritative, and **all state is in Redis**, so any pod can serve any room and a round goes on when the pod that started it goes away. Node.js 26 + TypeScript.

Decisions:
- [ADR 0019](../../docs/adr/0019-game-state-and-timers-in-redis.md): room state, timers and matchmaking in Redis;
- [ADR 0020](../../docs/adr/0020-game-client-protocol.md): the client protocol.

Operating it: [runbook](../../docs/runbooks/game.md).

## The game

- **Private rooms:** 2–8 players, a 6-character code (no 0/O/1/I/L), and a host who starts the game.
- **Quick play:** players join the open public room. It starts after a `QUICKPLAY_COUNTDOWN_SECONDS` countdown once it has `QUICKPLAY_MIN_PLAYERS`, or at once when 8 have joined. The same nickname twice in one public room becomes "דני 2".
- **Rounds:** each round picks a category, then a letter with at least 3 entries in that category (from the validator's `GET /v1/categories`), not repeating a pair within a game. Players have `ROUND_SECONDS` to answer.
- **Validation:** answers that are empty or blocked by the offensive-word filter are invalid. The validator checks the others: `valid`, `invalid` or `unknown`.
  - Unknown answers go to a `VOTE_SECONDS` room vote; a majority of the votes cast accepts, and a tie or no votes rejects. The author doesn't vote on their own answer.
  - When the validator fails twice, the answer counts as unknown too.
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
| `room:resume` | `{ roomCode, playerId, token }` | `state`: after a reconnect, on any pod |
| `game:start` | `{}` | host only, private rooms, 2+ players |
| `answer:submit` | `{ round, answer }` | can be resent until the deadline; the last one counts |
| `vote:cast` | `{ round, playerId, accept }` | `playerId` is the answer's author |
| `room:leave` | `{}` | before the game the player is gone; during it they're out, keeping their points |
| `room:sync` | `{}` | `state`, for a client that suspects it missed an event |

| Server → client | Payload |
|---|---|
| `room:state` | the room snapshot, after every change: players, scores, phase, `deadline`, `serverNow`, the last results |
| `round:start` | `{ round, letter, category: { id, name }, deadline, serverNow }` |
| `vote:start` | `{ round, items: [{ playerId, nickname, answer }], deadline, serverNow }` |
| `round:results` | `{ round, letter, category, answers: [{ playerId, nickname, answer, verdict, final, points, strike }], standings }` |
| `game:end` | `{ winners: [playerId], standings }` |
| `server:draining` | `{}`: reconnect (to another pod) and send `room:resume` |

Deadlines are epoch milliseconds from the server's clock. A client shows `deadline - serverNow` from the moment the event arrived, so a skewed phone clock doesn't matter.

Error codes:
- **requests:** `bad_request`, `rate_limited` (10 events in a burst, then 5 a second);
- **nicknames:** `bad_nickname` (2–16 letters, digits, spaces, `-`, `_`, `'`), `nickname_blocked`, `nickname_taken`;
- **joining:** `not_found`, `room_full`, `already_started`, `bad_token`, `not_in_room`;
- **game actions:** `not_host`, `not_enough_players`, `not_allowed`, `not_accepting`, `too_late`, `not_playing`, `not_voting`;
- **the server:** `draining`, `busy`, `unavailable` (Redis failed).

## Runtime endpoints

| Endpoint | Meaning |
|---|---|
| `GET /healthz` | Liveness: the process serves HTTP. It never checks Redis. |
| `GET /readyz` | 200 when Redis answers a PING within 1 s; 503 while draining or when Redis doesn't answer. New WebSocket connections are refused while it isn't ready. |
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
| `game_draining` | | 1 during shutdown |

The Node.js defaults come too, event-loop lag (`nodejs_eventloop_lag_seconds`) included. Logs are JSON on stdout, with `room_id` and `round`, and never contain answers or tokens.

## Configuration

Environment variables, checked at startup; the process exits listing every problem if one is wrong (never their values: URLs can hold passwords).

| Variable | Default | Notes |
|---|---|---|
| `REDIS_URL` | required | `redis://` or `rediss://`; one Redis, not Redis Cluster (ADR 0019) |
| `VALIDATOR_URL` | required | the validator's base URL, e.g. `http://validator:8080` |
| `GAME_PORT` | `8080` | HTTP and WebSocket |
| `SOCKET_PATH` | `/socket.io` | change it for path-based previews |
| `ALLOWED_ORIGINS` | empty (any) | comma-separated origins allowed to connect; set it outside local development |
| `ROUND_SECONDS` | `20` | 3–120 |
| `VOTE_SECONDS` | `5` | 2–60 |
| `RESULTS_SECONDS` | `5` | the pause after a round's results, 1–60 |
| `MAX_ROUNDS` | `10` | 1–30 |
| `MAX_STRIKES` | `3` | 1–10 |
| `QUICKPLAY_MIN_PLAYERS` | `3` | 2–8 |
| `QUICKPLAY_COUNTDOWN_SECONDS` | `15` | 0–120 |
| `ROOM_TTL_SECONDS` | `7200` | a room's keys expire after this long without activity |
| `DRAIN_DELAY_SECONDS` | `5` | how long readiness fails before players are told to reconnect |
| `SHUTDOWN_TIMEOUT_SECONDS` | `20` | then the process gives up waiting and exits 1 |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `GIT_SHA` | `unknown` | what `/version` reports; the image sets it |

## State in Redis

All keys start with `rb:`; `src/store.ts` lists them.
- **A room:** one JSON value, changed only by a compare-and-set script. The same script moves the room's entry in the `rb:deadlines` sorted set, so a crash can't leave a room without its timer.
- **Answers, votes and resume-token hashes:** small hashes beside it.
- **Timers:** every pod sweeps `rb:deadlines` every 200 ms. It takes a 15 s lease on a due room, and advances it only if the room is still in the state it read, so a transition happens once even when two pods race.
- **Answer events:** every scored answer goes to the stream `rb:answers` (trimmed near 100,000 entries) for the data pipeline.
- **Memory:** bounded by `ROOM_TTL_SECONDS` per room plus that stream.

## Shutdown

On SIGTERM:
1. Readiness fails, new players are refused (`draining`), and this pod stops advancing rooms (the others take over).
2. It keeps serving connected players for `DRAIN_DELAY_SECONDS`.
3. It sends `server:draining`; clients reconnect, and resume on another pod from Redis.
4. A second later it closes the sockets and Redis, and exits 0. A second SIGTERM exits at once.

The pod's `terminationGracePeriodSeconds` must exceed the drain delay + 1 s + a few seconds to close (≥ 15 s with the defaults). WebSocket connections idle for more than the load balancer's idle timeout are kept alive by Socket.IO's 10 s pings.

## Build and test

```bash
make game              # npm ci (scripts disabled), tsc type check, unit tests, build to dist/
make game-integration  # the Redis tests, against a throwaway redis:8.10.3-alpine container (Docker)
```

The unit tests cover:
- the rules (scoring, strikes, elimination, the end, winners, ties, the vote, picking rounds);
- the filter;
- config;
- the validator client against a fake HTTP server: retries, a 503, a validator that never answers.

The Redis tests run two game servers in one process as two pods:
- a whole game with the players on different pods;
- a pod dying mid-round while the other finishes the round;
- the vote;
- quick play across pods;
- the drain;
- offensive nicknames, and the metrics.

The cross-pod test fails without the Redis adapter (checked).

Run it locally: `npm run build && REDIS_URL=redis://127.0.0.1:6379 VALIDATOR_URL=http://127.0.0.1:8080 npm start` in `apps/game`. The docker compose stack comes with `make up`.
