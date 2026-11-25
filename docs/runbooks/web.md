# Runbook: the web UI doesn't load, or doesn't connect

- **Alert(s):** none yet; with the monitoring stack, the game's alerts and the synthetic game cover what players feel.
- **Service:** [`catalog/web.yaml`](../../catalog/web.yaml)
- **Severity:** page (nobody can play)
- **Last fired on purpose:** not yet; the image and its probes come next.

## What it means

The UI is static files ([apps/web](../../apps/web/README.md)). It fails in one of two places:
- **it doesn't load:** a blank page, or the HTML loads without its scripts and styles;
- **it loads but doesn't connect:** the home screen stays on "מתחברים…" (connecting), or a joined player sees the reconnecting banner and never gets back.

## Diagnose (first 5 minutes)

1. Open the browser's developer tools on the page (or `curl -sI <url>` and `curl -sI <url>/assets/<file>.js`).
2. Match what you see:

| Symptom | Cause | Fix |
|---|---|---|
| 404 for `assets/*.js` or `*.css` | the page is served from a path the files aren't under (a prefix not mapped to the same directory) | serve the whole `dist/` at the page's path; the build uses relative URLs, so it works under any prefix |
| "מתחברים…" forever; the WebSocket gets `400` | the game refused the upgrade: the page's origin isn't in its `ALLOWED_ORIGINS`, or no game pod is ready | add the origin; check the game pods ([game runbook](game.md)) |
| the WebSocket gets `404` | the game's `SOCKET_PATH` doesn't match `<page prefix>socket.io` | set `SOCKET_PATH` to the prefix plus `socket.io` |
| the reconnecting banner never clears | the game is down, or Redis lost the room | [game runbook](game.md); a lost room shows "אי אפשר לחזור לחדר" (can't get back into the room) |
| works on Wi-Fi, not on mobile data (or the reverse) | a proxy or firewall dropping WebSockets | test with `wscat` or the bots from that network; the load balancer must allow WebSocket upgrades on the game's path |

## Fix

The UI holds no state of its own beyond the player's seat in `localStorage`: redeploying it is always safe. Changes to `ALLOWED_ORIGINS` or `SOCKET_PATH` are game settings (a PR to its values).

## Verify

- The page loads at its URL on a phone, and the home screen's buttons become active (connected).
- A quick-play game with the bots (`docker compose -f compose/compose.yaml run --rm bots synthetic --game-mode quickplay --players 2` locally) reaches the end screen in the browser.

## Roll back or escalate

- A bad UI release: roll the image back; players reload and resume.
- Connection problems that aren't the UI's: the game's runbook.

## Prevention

- Browser tests across OSes and browsers with the test arena.
- The synthetic game covers the game; the UI's own synthetic check (load the page, connect) comes with its image.
