# Runbook: the synthetic game failed, or a bots run reports failed games

- **Alert(s):** none yet; with the monitoring stack, a failed synthetic Job (the game, seen from outside) pages through the game's alerts.
- **Service:** [`catalog/bots.yaml`](../../catalog/bots.yaml); what it tests is [`catalog/game.yaml`](../../catalog/game.yaml).
- **Severity:** what it found decides: a synthetic game that fails twice in a row is the game failing for players.
- **Last fired on purpose:** 2026-11-25, in the integration tests: both game servers killed mid-game → the game failed with `couldn't reconnect`, in under 30 s.

## What it means

The bots exit 1 when a game failed (exit 2 is their own bad options). Each failed game is a `game` line with `"ok":false` and a `failure`; the `summary` line lists the first 20.

## Diagnose (first 5 minutes)

1. The failure reasons:
   ```bash
   kubectl -n <namespace> logs job/<bots-job> | grep '"msg":"game"' | grep '"ok":false'
   kubectl -n <namespace> logs job/<bots-job> | grep '"msg":"summary"'
   ```
   Locally: the same lines on stdout.
2. Match the reason:

| `failure` starts with | Means | Look at |
|---|---|---|
| `room:create:` / `room:join:` / `quickplay:join:` with `unavailable` | the game couldn't reach Redis | [game runbook](game.md) → Redis |
| `game:start:` | the game refused to start the room | the code after it (`not_enough_players`: a bot didn't join) |
| `bot N: couldn't reconnect within` | no game server accepted the bot for that long | game pods ready? (`kubectl get pods -l app.kubernetes.io/name=game`); the bots' `--url`; `too_many_connections` in the last error means `MAX_CONNECTIONS_PER_IP` is too low for a load test |
| `bot N: resume refused: bad_token` or `not_found` | the bot's seat is gone: the room expired or was deleted, or Redis lost its data (a restart without persistence) | [game runbook](game.md) → Redis down |
| `the game ended, but bot N never saw the end` | the bot was connected but no longer got the room's events: it reconnected without getting back into the room | a bots bug (resume) or the game's fan-out between pods (`couldn't publish to other pods` in the game's log) |
| `stalled: phase X, round N, ... ms past its deadline` | no game pod advanced the room | [game runbook](game.md) → rounds stall (the deadline set, leases) |
| `no end within` with `notice waiting_for_categories` | rounds can't start: no categories | [validator runbook](validator.md) |
| `no end within` otherwise | the game is slow, or `--timeout` is too short for the server's round settings | the server's `ROUND_SECONDS` × `MAX_ROUNDS` |
| `unexpected replies:` | the server sent an error a correct client doesn't get | the codes listed: `unavailable` → Redis; `rate_limited` → a bot bug (open an issue); `not_in_room` → a resume problem |
| `scores don't add up` / `the bots disagree on the winners` | the game scored wrong | a game bug: open an issue with the `game` line and the room code |
| `websocket error`, at once (the first connect) | the game refused the WebSocket upgrade: the bots' `--origin` isn't in its `ALLOWED_ORIGINS`, or no pod is ready (a pod that isn't ready refuses new connections) | the Job's `--origin`; the game pods' readiness |

3. The `summary` line's `counts` show error codes per event (`error.answer:submit.unavailable`), resends, watchdog syncs and draining notices; `latency_ms` shows whether the game got slow before it failed.

## Fix

Fix what the matching runbook says. The bots hold no state: rerunning a Job is always safe. A synthetic room left behind expires on its own (10 minutes after its game ends, 2 hours at most).

## Verify

- A synthetic run exits 0 and its summary has `"passed":true`.
- After a fix to the game: an `observe` run while killing a game pod (the drill) reports 0 failed games.

## Roll back or escalate

- A bots release that fails good games (its failures all point at the bots, e.g. `rate_limited`): roll the bots image back; the game is fine.
- Everything else: it's the game's incident; follow the game's runbook.

## Prevention

- The synthetic game runs on a schedule against every environment once the platform exists.
- The bots' integration tests run the drills (a pod killed, a pod drained, every pod gone) against the real game server.
