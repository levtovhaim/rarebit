# Runbook: game not ready, or rounds stall

- **Alert(s):** none yet; they come with the monitoring stack (no ready game pod, `game_redis_errors_total` rising, rooms past their deadline).
- **Service:** [`catalog/game.yaml`](../../catalog/game.yaml)
- **Severity:** page (nobody can play)
- **Last fired on purpose:** 2026-11-25, in the integration tests:
  - a game pod closed mid-round: the other pod finished the round, and the players resumed there;
  - a drain: readiness 503 at once, `server:draining` to the connected players after the drain delay.

## What it means

- `/readyz` is 503 when:
  - the pod is draining (SIGTERM; expected during rollouts);
  - or Redis didn't answer a PING within 1 s. A pod that isn't ready also refuses new WebSocket connections.
- Rounds stall when no pod advances them:
  - no game pod has a working Redis connection;
  - or every pod is draining;
  - or a pod died while evaluating a round. That holds its 15 s lease, and the room waits that long once.
- Rounds go on but every answer goes to the vote: the validator is down or failing. A round can't *start* without the playable categories, which the game caches for a minute. With no cached copy, rooms retry every 2 s.

## Impact on players

- **No ready pod:** nobody can join, and connected players' actions fail with `unavailable`.
- **A stalled room:** its countdown reaches zero and nothing happens. Clients can ask with `room:sync`.
- **Validator down:** every answer needs a vote, so rounds are slower but still scored.

## Diagnose (first 5 minutes)

1. Which pods are ready, and why the others aren't:
   ```bash
   kubectl -n <namespace> get pods -l app.kubernetes.io/name=game
   kubectl -n <namespace> logs <pod> --since=10m | grep -E '"level":"(warn|error)"'
   ```
   - `redis error`, `ECONNREFUSED`, `Socket closed unexpectedly`: Redis is down or unreachable. Check Redis and NetworkPolicies.
   - `validator unreachable`, `no categories from the validator`: the validator, see [its runbook](validator.md).
2. Rooms past their deadline: anything more than a few seconds old means nobody is sweeping.
   ```bash
   redis-cli ZRANGEBYSCORE rb:deadlines -inf "$(( $(date +%s%3N) - 5000 ))" WITHSCORES
   redis-cli --scan --pattern 'rb:lease:*'        # who is advancing what (value = pod id)
   ```
3. One room: `redis-cli GET rb:room:<CODE>`. It's JSON: `phase`, `round`, `deadline` (epoch ms), the players.
4. Metrics:
   - `game_redis_errors_total` rising;
   - `game_draining` 1 on every pod;
   - `game_answers_total{result="accepted"|"rejected"}` spiking (the validator is out and everything goes to the vote).

## Fix

| Cause | Fix |
|---|---|
| Redis down | Restore Redis (its own runbook). The game reconnects by itself, with backoff of up to 2 s; rooms resume from their keys, which expire only after 2 h without activity. |
| Every game pod draining or crash-looping | Check the rollout (`kubectl rollout status deploy/game`) and the logs for `invalid configuration` (the config is listed in the message, minus values). |
| A room stuck with a lease held by a dead pod | Wait 15 s: the lease expires and another pod takes it. If it doesn't, check that some pod is ready. |
| Validator down | Fix the validator; nothing to do in the game. |

Every command above is read-only. Deleting a room's keys (`DEL rb:room:<CODE>`) ends that game for its players: that's state-changing, so a human runs it or approves it in a shared environment (CLAUDE.md → Rules, rule 2).

## Verify

- `curl -s <pod>/readyz` returns `{"status":"ready"}`.
- `ZRANGEBYSCORE rb:deadlines -inf <now - 5 s>` is empty.
- A bot game finishes: the synthetic game, once the bots exist.

## Roll back or escalate

- A bad game release: roll the image back. Room state is compatible as long as the room JSON only gains fields. A field the old code doesn't know is ignored, and one it expects but is missing would break it, so remove fields across two releases.
- Redis itself: escalate to whoever owns the data layer; the game can't run without it (ADR 0019).

## Prevention

- Alerts on readiness, Redis errors and stuck deadlines, linked to this runbook, with the monitoring stack.
- The test arena kills game pods during play on every preview.
