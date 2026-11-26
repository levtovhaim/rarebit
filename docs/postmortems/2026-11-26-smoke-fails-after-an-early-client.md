# Postmortem: `make smoke` failed after a client connected during `make up`

- **Date and duration:** 2026-11-25, 20:36–21:00 UTC (found while verifying PR #43); reproduced and fixed 2026-11-26
- **Type:** incident (the local stack's smoke gate)
- **Authors:** platform owner
- **Status:** draft

Blameless: describe what the system and the process allowed, not who made a mistake.

## Summary

`make smoke` failed 2 times in 5 right after `make up` while a browser tab had the web UI open. The tab reconnected while the stack was starting, nginx marked both game replicas as failed, and for as long as WebSockets stayed open each replica admitted only one new connection per 5 s, so one of the three bots got a 502. Fixed by turning off nginx's passive failure marking for the game replicas (`max_fails=0`) and capping the connect timeout at 2 s; a new drill reproduces it.

## Impact

- No players: local stack only.
- 2 of 5 `make smoke` runs failed with "websocket error", with no code change between runs. A flaky gate teaches people to rerun until green.

## Timeline (UTC)

| Time | Event |
|---|---|
| 2026-11-25 20:36 | `make smoke` fails after `make up`: 1 game, `"failure":"websocket error"`, 52 ms |
| 20:38 | The same `make smoke` passes on its own; 2 more up/smoke runs pass |
| 20:44 | A run fails again; with the stack's logs kept: nginx logged a WebSocket from the host at 20:44:18 refused by both replicas, then `no live upstreams` for the bots at 20:44:30 |
| after 20:45 | Hypothesis: a browser tab left open on `127.0.0.1:8080` reconnects during `make up`. With the tab closed: 3 of 3 pass |
| 2026-11-26 04:57 | Reproduced without a browser: one WebSocket the moment nginx answers, then `make smoke`: fails |
| 04:58 | Counting run: after the early failure, 4 WebSockets in 2–3.5 s all get 502; 10 s after it, one per replica gets through |
| after 05:00 | Fix (`max_fails=0`, `proxy_connect_timeout 2s`): the drill passes 3 of 3; on the old config it fails; the kill and drain drills pass |

## Root cause and trigger

**Trigger:** a client connected to `/socket.io/` after nginx started but before the game replicas listened. `make up` starts nginx once the replicas have *started*, not when they're healthy, on purpose (ADR 0024). Both replicas refused, and nginx counted one failure for each (`max_fails=1`).

**Root cause:** nginx's passive health marking assumes short requests.
- A replica with `max_fails` failures is skipped for `fail_timeout` (5 s).
- After that, nginx lets one request through as a test, and restarts the 5 s window at that moment.
- The failure count resets only when that test request *finishes* successfully.
- A WebSocket request finishes when the connection closes, which for a player is the end of the game. nginx logged the test WebSockets' `101` lines 20 s after they opened, when they closed.

So while WebSockets stayed open, each "failed" replica admitted one new connection per 5 s. `make smoke`'s three bots connect at once, and the third got `no live upstreams`.

Open-source nginx has no active health checks to clear the mark sooner.

## What went well, what went badly, where we got lucky

- **Well:**
  - The bots fail a game on any unexpected connection error, so the problem surfaced instead of being retried away.
  - Keeping the stack's logs on failure made the second occurrence explainable.
- **Badly:**
  - The first failure's reason was cut off by an output filter, and the stack was removed before anyone read its logs.
  - Nothing in the drills covered a client arriving during startup.
- **Lucky:** it showed up locally, through an open browser tab, not as rare 502s for players behind a proxy configured the same way.

## Action items

| Action | Type (prevent / detect / mitigate) | Owner | Issue |
|---|---|---|---|
| Game upstream: `max_fails=0`, `proxy_connect_timeout 2s` in `compose/nginx.conf` | prevent | platform owner | this PR |
| Drill `compose/test/early-client.sh`: a WebSocket during startup, then `make smoke` | detect | platform owner | this PR |
| No passive failure marking (`max_fails`) in front of WebSocket backends; health comes from readiness and the load balancer's active checks in the cluster | prevent | platform owner | for the chart PR (ALB target group health checks) |
