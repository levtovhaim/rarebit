# bots

Simulated players for the game: the synthetic game (black-box monitoring), load tests, and the chaos observer. Node.js 26 + TypeScript + `socket.io-client`. Each bot is a real client of the game's protocol ([ADR 0020](../../docs/adr/0020-game-client-protocol.md)): it reconnects with jitter, resumes with its token, runs the deadline watchdog and moves on when a server drains. So a bots run tests what a phone would see.

Decision: [ADR 0023](../../docs/adr/0023-bots-protocol-clients-judged-by-failed-games.md). Operating it: [runbook](../../docs/runbooks/bots.md).

## Modes

```bash
node dist/main.js synthetic --url https://game.example --origin https://rarebit.example
node dist/main.js load      --url http://game:8080 --rooms 50 --players 6 --games 3
node dist/main.js observe   --url http://game:8080 --rooms 10 --duration 600
```

| Mode | What it does | Passes when |
|---|---|---|
| `synthetic` | one game | it finished correctly |
| `load` | `--rooms` games at once, `--games` each, one after another; rooms start `--ramp` ms apart | at most `--max-failed` games failed, and at least one finished |
| `observe` | the chaos observer: games in `--rooms` rooms back to back for `--duration` seconds, or until SIGTERM; each game's result is printed as it ends | the same as `load` |

Load and observe always use private rooms, so their games never mix with each other's or with real players'. Synthetic uses a private room too, unless `--game-mode quickplay` (for tests: in a shared environment it would join real players).

Exit codes: **0** passed, **1** failed, **2** bad options or unreadable word lists. SIGTERM or SIGINT stops starting games and lets running ones finish (a synthetic run aborts at once, and fails); a second signal aborts the running games.

## Options

Every option has an environment variable, for Jobs; the command line wins.

| Option | Variable | Default | |
|---|---|---|---|
| `--url` | `BOTS_URL` | required | the game's base URL; several, comma-separated, and bots spread over them and move to the next on a reconnect (behind a load balancer, give one) |
| `--origin` | `BOTS_ORIGIN` | none | the Origin header; the game checks it against its `ALLOWED_ORIGINS` |
| `--socket-path` | `BOTS_SOCKET_PATH` | `/socket.io` | the game's `SOCKET_PATH` |
| `--words` | `BOTS_WORDS_DIR` | `data/categories` in the repo | the word lists the scripted bots answer from |
| `--players` | `BOTS_PLAYERS` | `3` | bots per game, 2–8 |
| `--rooms` | `BOTS_ROOMS` | `1` | games at once, 1–1000 |
| `--games` | `BOTS_GAMES` | `1` | load: games per room |
| `--duration` | `BOTS_DURATION` | `300` | observe: seconds |
| `--game-mode` | `BOTS_GAME_MODE` | `private` | `quickplay` only for synthetic |
| `--timeout` | `BOTS_TIMEOUT` | `900` | seconds a game may take (a 10-round game with the server's defaults takes about 5 minutes) |
| `--stall-grace` | `BOTS_STALL_GRACE` | `30` | seconds a phase may sit past its deadline: longer than a lease (15 s) plus a sweep |
| `--ramp` | `BOTS_RAMP` | `100` | ms between starting rooms |
| `--max-failed` | `BOTS_MAX_FAILED` | `0` | failed games a load or observe run tolerates |
| `--strategy` | `BOTS_STRATEGY` | `scripted` | how the bots play (below) |
| `--seed` | `BOTS_SEED` | random | an integer: the same seed plays the same answers and votes |
| `--ack-timeout` | `BOTS_ACK_TIMEOUT` | `5000` | ms to wait for a reply |
| `--reconnect-give-up` | `BOTS_RECONNECT_GIVE_UP` | `30` | seconds a bot keeps reconnecting before its game fails |
| `--log-level` | `BOTS_LOG_LEVEL` | `info` | |

`GIT_SHA` goes into every log line as `version`.

## What counts as a failed game

A game fails when:
- it doesn't end within `--timeout`, or a phase sits more than `--stall-grace` past its deadline (the sweeper stopped);
- a bot can't reconnect within `--reconnect-give-up`, or its resume is refused (its seat is gone);
- the game ended for some bots, but another hasn't seen the end `--reconnect-give-up` + 5 s later: it lost its room without noticing;
- the server answers with an error a well-behaved client never gets (`unavailable`, `busy`, `rate_limited`, `not_in_room`, a timeout after a resend...). `too_late`, `not_accepting` and `not_playing` for answers, and `too_late`, `not_voting`, `not_allowed` and `not_found` for votes, are normal;
- the bots disagree on the winners, or a player's final score or strikes aren't the sum of their round results. When every bot missed some round's results (all of them reconnecting at once), the score check is `skipped`, not failed.

## Output

JSON lines on stdout. Every finished game is a `game` line:

```json
{"level":"info","msg":"game","ok":true,"aborted":false,"mode":"private","room":"K7Q2MX","players":3,"rounds":10,
 "duration_ms":301234,"winners":["..."],"failure":null,"checks":{"ended":true,"winners_agree":true,"scores":"ok"},
 "reconnects":0,"resumes":0,"unexpected_errors":[]}
```

The run ends with a `summary` line: games, `ok`, `failed`, `aborted`, `passed`, the first 20 failures, game durations, reconnects and resumes, acknowledgement latency per event (`latency_ms`: n, p50, p95, p99, max) and counters (`counts`: error codes per event, resends, watchdog syncs, draining notices).

## Strategies: the persona hook

How a bot plays is a `Strategy` ([`src/strategy.ts`](src/strategy.ts)): a nickname, an answer for a round (`{ text, afterMs }` or none) and a vote on another player's answer (accept, reject or abstain). Both may be async, so a persona that asks a model fits. The client and the game flow never pick an answer or a vote themselves.

The built-in `scripted` strategy answers with a listed word 75% of the time, a made-up word with the round's letter 15% (rejected, or voted on), and nothing 10%, between 20% and 70% of the way through the round; it accepts half the votes. A new persona is a new `Strategy`, registered by name in `strategy.ts`.

## Running against an environment

- **One URL** behind the load balancer; the bots don't need to know the pods.
- **`--origin`** must be in the game's `ALLOWED_ORIGINS`.
- **Load tests come from a few addresses:** the game accepts `MAX_CONNECTIONS_PER_IP` connections per address per pod (default 20). Raise it on the target, or connections fail with `too_many_connections`.
- **Rooms are real rooms:** they live in the game's Redis until their TTL (10 minutes after a game ends).

## Build and test

```bash
make bots              # npm ci (scripts disabled), tsc type check, unit tests, build to dist/
make bots-integration  # the bots against two real game servers (apps/game/dist), a throwaway Redis and a fake validator
```

`make bots-integration` needs `make game` and `make bots` first. Its fake validator judges answers by the word lists: a listed word is valid, an unlisted one with the round's letter is unknown (so the room votes), anything else invalid.

The unit tests cover the options, the scripted strategy (answer mix, timing, votes, the same seed giving the same run), the word lists and the percentiles. The integration tests:
- a private game with a vote, the scores checked;
- a quick-play game: the bots meet in one public room;
- four games at once, each room's bots spread over both servers;
- a server SIGKILLed mid-round: every game finishes, the bots resume on the other server;
- a server drained (SIGTERM) mid-round: every game finishes, and the server exits 0;
- both servers gone: the game fails with the reason, in bounded time;
- the command itself: `synthetic` exits 0 with its summary line, bad options exit 2.
