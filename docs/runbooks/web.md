# Runbook: the web UI doesn't load, doesn't connect, or loads wrong

- **Alert(s):** none yet; with the monitoring stack, the game's alerts and the synthetic game cover what players feel.
- **Service:** [`catalog/web.yaml`](../../catalog/web.yaml)
- **Severity:** page (nobody can play)
- **Last fired on purpose:** 2026-11-25, `make web-image-smoke` and its negative controls: an image without `add_header_inherit merge` (the page lost its CSP), one with fonts inlined as `data:` URLs (blocked by the CSP), and a stop by SIGTERM instead of the image's SIGQUIT (the download in flight was cut off).

## What it means

The UI is static files served by nginx from the web image ([apps/web](../../apps/web/README.md), ADRs 0027–0029). It fails in one of three places:
- **it doesn't load:** a blank page, or the HTML loads without its scripts and styles;
- **it loads but doesn't connect:** the home screen stays on "מתחברים…" (connecting), or a joined player sees the reconnecting banner and never gets back;
- **it loads wrong:** an old version after a deploy, or fonts that look different (a blocked font falls back silently).

## Diagnose (first 5 minutes)

1. Is the pod serving? `kubectl get pods -l app.kubernetes.io/name=web`, then from inside the cluster `curl -s http://<pod-ip>:8080/version` and `curl -s http://<pod-ip>:9113/metrics` (the metrics port; no Ingress routes it). Locally: `docker compose -f compose/compose.yaml ps web` and `curl -s http://127.0.0.1:8080/version`.
2. Open the browser's developer tools on the page: the Console for Content-Security-Policy errors, and the Network tab for each request's status. Or use `curl -sI <url>` and `curl -sI <url>assets/<file>.js`.
3. Match what you see:

| Symptom | Cause | Fix |
|---|---|---|
| the pod restarts, its log says `Read-only file system` | no writable `/tmp`: the pod spec lacks the emptyDir (locally, the tmpfs) | mount an emptyDir at `/tmp` |
| the pod doesn't start, `nginx: [emerg]` in its log | a configuration error that `nginx -t` at build time didn't catch (for example a missing include after an edit) | roll back the image; fix `apps/web/nginx.conf` and rebuild |
| 404 for `assets/*.js` or `*.css` | the page's prefix doesn't reach this pod, or the path has characters the server doesn't serve (a prefix segment other than letters, digits, `_ . ~ -`) | route the prefix to the web service; keep preview prefixes plain (`/pr-12/`) |
| "מתחברים…" forever; the WebSocket gets `400` | the game refused the upgrade: the page's origin isn't in its `ALLOWED_ORIGINS`, or no game pod is ready | add the origin; check the game pods ([game runbook](game.md)) |
| the WebSocket gets `404`, or the web server's own 404 page | `<page prefix>socket.io` isn't routed to the game, or the game's `SOCKET_PATH` doesn't match it | route the socket path to the game; set `SOCKET_PATH` to the prefix plus `socket.io` |
| a `Content-Security-Policy` error in the console | something the page loads isn't from its own origin (or is a `data:` font) | ship it as a file of the build, or change the policy in `nginx.conf` (ADR 0029) |
| a blank page during a rollout, 404s for `assets/index-*.js` in the Network tab; a reload fixes it | old and new pods side by side: the page came from one version, its assets were asked of the other | it ends when the rollout does; for good, the rollout setting in `apps/web/README.md` → Settings the deployment must get right |
| 502s or refused connections for a few seconds on every deploy or node drain | the pod stopped before the load balancer dropped it: no preStop sleep, or one shorter than the deregistration | the preStop and deregistration settings in `apps/web/README.md` |
| players see the old version after a deploy | something in between caches `index.html` (a CDN or proxy that ignores `no-cache`), or the page itself came with a long `max-age` | `curl -sI <url>` must show `Cache-Control: no-cache` on the page; fix the layer that adds caching |
| the reconnecting banner never clears | the game is down, or Redis lost the room | [game runbook](game.md); a lost room shows "אי אפשר לחזור לחדר" (can't get back into the room) |
| works on Wi-Fi, not on mobile data (or the reverse) | a proxy or firewall dropping WebSockets | test with the bots from that network; the load balancer must allow WebSocket upgrades on the game's path |

## Fix

The UI holds no state of its own beyond the player's seat in `localStorage`, so redeploying it is always safe. Stopping a pod is graceful: SIGQUIT finishes the downloads in flight. A new build never breaks a page already open: its asset names are new, so the old page keeps its old files until it reloads. Changes to `ALLOWED_ORIGINS` or `SOCKET_PATH` are game settings (a PR to its values).

## Verify

- `/version` shows the expected SHA, and the page loads on a phone with no console errors. The home screen's buttons become active once it's connected.
- A quick-play game with the bots (`docker compose -f compose/compose.yaml run --rm bots synthetic --game-mode quickplay --players 2` locally) reaches the end screen in the browser.

## Roll back or escalate

- A bad UI release: roll the image back. Players get the old page on their next load, because `index.html` is revalidated every time.
- Connection problems that aren't the UI's: the game's runbook.

## Prevention

- `make web-image-smoke` on every change to `apps/web`: the contract, the caching rules, the security headers, no inlined fonts, a graceful stop with a download in flight.
- `make smoke` checks that the local stack's nginx serves the UI at `/`.
- Browser tests across OSes and browsers come with the test arena, and they'll fail on CSP errors in the console.
