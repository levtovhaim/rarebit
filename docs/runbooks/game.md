# Runbook: game not ready, or rounds stall

- **Alert(s):** none yet; they come with the monitoring stack (no ready game pod, `game_redis_errors_total` rising, rooms past their deadline).
- **Service:** [`catalog/game.yaml`](../../catalog/game.yaml)
- **Severity:** page (nobody can play)
- **Last fired on purpose:** 2026-11-25, in the integration tests:
  - a game pod shut down mid-round: the other pod finished the round, and the players resumed there;
  - Redis dropped every client connection mid-round: the pod reconnected, finished the round, and was ready again;
  - Redis refused the publishing connection's reconnect for a while: broadcasts failed (`couldn't publish to other pods`), the round still started, readiness was 503 until the connection was back;
  - 25 deadline entries for rooms that no longer exist: the sweep removed them and the next game started on time;
  - a drain: readiness 503 at once, `server:draining` to the connected players after the drain delay.

## What it means

- `/readyz` is 503 when:
  - the pod is draining (SIGTERM; expected during rollouts);
  - or one of its three Redis connections is down, or a write to Redis didn't succeed within 1 s (a read-only replica after a failover fails it too). A pod that isn't ready also refuses new WebSocket connections.
- Rounds stall when no pod advances them:
  - no game pod has a working Redis connection;
  - or every pod is draining;
  - or a pod died while advancing a room. That holds its 15 s lease, and the room waits that long once.
- A round can't *start* without the playable categories. Each pod caches the validator's list for a minute and shares the last one through Redis (`rb:categories`, kept an hour). With neither, the room retries after 2, 4, 8, then every 10 s, and its state shows `notice: "waiting_for_categories"`.
- Rounds go on but every answer goes to the vote: the validator is down or failing (answers it can't judge count as unknown).

## Impact on players

- **No ready pod:** nobody can join, and connected players' actions fail with `unavailable`.
- **A stalled room:** its countdown reaches zero and nothing happens. Clients ask with `room:sync` after 1.5 s.
- **Validator down:** every answer needs a vote, so rounds are slower but still scored. New rounds start as long as some pod has the categories cached or shared.

## Diagnose (first 5 minutes)

1. Which pods are ready, and why the others aren't:
   ```bash
   kubectl -n <namespace> get pods -l app.kubernetes.io/name=game
   kubectl -n <namespace> logs <pod> --since=10m | grep -E '"level":"(warn|error)"'
   ```
   Log lines (`msg`) and what they point at:
   - `redis error`, `sweep failed`, `couldn't publish to other pods`, `clock sync failed`: Redis is down, unreachable or failing over. Check Redis and NetworkPolicies.
   - `advancing the room failed` (with `room_id`): one room's transition failed; another sweep retries it after the lease (15 s).
   - `validator unreachable`, `validator refused the answer`, `no categories from the validator; trying again`: the validator, see [its runbook](validator.md).
   - `categories unavailable, using the cached list` or `... the list another pod shared`: the validator is down, and rounds still start from the last good list.
   - `unhandled rejection`: a bug; the pod keeps serving. Open an issue with the line.
2. Rooms past their deadline. A room being advanced has its entry pushed 15 s ahead, so an entry more than 15 s overdue means nobody is sweeping it:
   ```bash
   redis-cli ZRANGEBYSCORE rb:deadlines -inf "$(( $(date +%s%3N) - 15000 ))" WITHSCORES
   redis-cli --scan --pattern 'rb:lease:*'        # who is advancing what (value = pod id)
   ```
3. Which pod holds which connection: `redis-cli CLIENT LIST | grep rarebit-game` (each is named `rarebit-game:<pod>`, `...:sub` or `...:pub`).
4. One room: `redis-cli GET rb:room:<CODE>`. It's JSON: `phase`, `round`, `deadline` (epoch ms, Redis's clock), `notice`, the players.
5. Metrics (PromQL):
   - `sum(rate(game_redis_errors_total[5m]))` rising;
   - `min(game_draining) == 1`: every pod is draining;
   - `sum(rate(game_answers_total{result=~"accepted|rejected"}[5m]))` spiking: the validator is out and everything goes to the vote.
   - `sum by (reason) (rate(game_connections_refused_total[5m]))`: players turned away. `not_ready`: pods starting, draining or without Redis. `origin`: the page's origin isn't in `ALLOWED_ORIGINS`. `per_ip`: over `MAX_CONNECTIONS_PER_IP`; if many players hit it at once, check `TRUSTED_PROXY_HOPS` is 1 behind the ALB (with 0, every player counts as the load balancer's address).

## Fix

| Cause | Fix |
|---|---|
| Redis down | Restore Redis (its own runbook). The game reconnects by itself, with backoff of up to 2 s; rooms resume from their keys. Without Redis persistence, a restart has lost every running game: players get `not_found` on resume and start a new one. |
| Redis failed over to a replica | Readiness fails while the pods' connections still point at the old primary; they reconnect through the Service. If they don't within a minute, restart the game pods (`kubectl rollout restart deploy/game`: state-changing). |
| Every game pod draining or crash-looping | Check the rollout (`kubectl rollout status deploy/game`) and the logs for `invalid configuration` (the message lists each problem, minus values). |
| A room stuck with a lease held by a dead pod | Wait 15 s: the lease expires and another pod takes it. If it doesn't, check that some pod is ready. |
| Validator down | Fix the validator; nothing to do in the game. |
| `exec: "/bin/sh": ... no such file or directory` at container start, or `FailedPreStopHook` | Something runs a shell in an image that has none (ADR 0022): a shell-form command, an `exec` probe or a shell `preStop`. Use `httpGet` probes, and exec form for any command; for a command health check, `/nodejs/bin/node /app/dist/check-ready.js`. |
| `Cannot use import statement outside a module`, or `ERR_MODULE_NOT_FOUND` at start | The image is missing `package.json` (its `"type": "module"`) or a production dependency: an image not built from `apps/game/Dockerfile` as committed. Rebuild it. |
| Pods killed during rollouts without `server:draining` reaching players (no `"msg":"draining"` in the log before the pod went) | The server isn't PID 1 (a wrapper such as `npm start` or a shell is in between), or `terminationGracePeriodSeconds` is shorter than the drain (apps/game/README.md → Shutdown). |

Every command in Diagnose is read-only. To end one stuck game by hand, delete its keys and its timer together:

```bash
redis-cli DEL rb:room:<CODE> rb:room:<CODE>:t
redis-cli ZREM rb:deadlines <CODE>
```

That ends the game for its players, so it's state-changing: in a shared environment a human runs it or approves the exact command (CLAUDE.md → Rules, rule 2). Its answer and vote hashes expire by themselves.

## Verify

- `curl -s <pod>/readyz` returns `{"status":"ready"}`.
- `ZRANGEBYSCORE rb:deadlines -inf <now - 15 s>` is empty.
- A bot game finishes: the bots' synthetic game against the environment ([apps/bots](../../apps/bots/README.md); locally, `make smoke`).

## Roll back or escalate

- A bad game release: roll the image back. Room state is compatible as long as the room JSON only gains fields. A field the old code doesn't know is ignored, and one it expects but is missing would break it, so remove fields across two releases.
- Redis itself: escalate to whoever owns the data layer; the game can't run without it (ADR 0019).

## Prevention

- Alerts on readiness, Redis errors and stuck deadlines, linked to this runbook, with the monitoring stack.
- The test arena kills game pods during play on every preview.
- Redis with `maxmemory-policy noeviction`, persistence and a replica (ADR 0019, follow-ups).
