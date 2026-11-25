# web

The game on a phone: Hebrew, right to left, one hand. React + Vite, built to static files. Each player's phone talks to the game server over Socket.IO, as a client of its protocol ([ADR 0020](../../docs/adr/0020-game-client-protocol.md)). Decisions: [ADR 0026](../../docs/adr/0026-web-ui-static-bundle-from-the-snapshot.md). Operating it: [runbook](../../docs/runbooks/web.md).

## The screens

| Screen | When | What's on it |
|---|---|---|
| Home | no room | the nickname, open a private room, quick play, join with a code (a `?room=CODE` link fills it in) |
| Lobby, private | before the game | the room code (one notebook square per character, read aloud easily), a QR code of the join link, sharing, the players, the host's start button |
| Lobby, quick play | waiting for players | the players, and the countdown once enough are connected |
| Round | `round` | the letter and the category, the timer, the answer field in the thumb zone; "eliminated, your points are kept" for a player out of the game |
| Vote | `voting` | each unknown answer, accept or reject |
| Results | `results` | every answer with its verdict as a mark and a word, the points, strikes, the standings |
| End | `ended` | the winners (a tie shows them all), the standings, a new game |
| Reconnecting | the connection dropped, or the server drains | a banner over the screen; the game goes on underneath once the player is back |
| Lost | the room can't be rejoined | what happened, and the way home |

Every screen renders from the room snapshot the server pushes. The app adds only what the server doesn't keep for this player: the connection, the answer sent, the votes cast.

## The design

A squared school notebook, the paper the game is played on:
- **Palette:** paper `#FBFCFE`, a faint blue grid `#C7D6EC`, graphite text `#26282C`, ballpoint ink `#2340B8` for the letter and the actions, a red pen `#C8102E` for strikes and the last seconds, a highlighter `#FFE14D` for "you".
- **Type, all with real Hebrew glyphs, self-hosted:** Karantina (display: the letter, titles, answers being voted on), IBM Plex Sans Hebrew (text), IBM Plex Mono (room codes, scores, the seconds). The font files are split by script, so a phone downloads only the ones it uses.
- **The timer:** one notebook square per second of the phase, crossed out as time passes, and the seconds beside it. It's drawn from the server's deadline and clock (`serverNow`), never from the phone's. In a round's last 5 seconds, the number grows, gains a "!" and turns red, and the remaining squares get a red outline and grow. With `prefers-reduced-motion` they don't pulse.
- **Never by color alone:** verdicts carry a mark and a word (✓ correct, ✗ incorrect, accepted or rejected by vote, – no answer, ⊘ blocked); strikes are ✗ marks and the word.
- **Phones:** designed at 360–414 px, tap targets of 44 px or more, the answer field and the buttons at the bottom within thumb reach (and above the keyboard: `interactive-widget=resizes-content`), safe-area insets, no horizontal scroll.

## How it connects

- **To the game:** WebSocket only, at `<page path>socket.io`. Served at `/` that's `/socket.io`, at `/pr-12/` it's `/pr-12/socket.io`, so the game's `SOCKET_PATH` must match. The build uses relative asset URLs, so one build works at any path.
- **Back into a room:** the seat (room code, player id, token) is kept in `localStorage`. After a reload, a dropped connection or `server:draining`, the app waits a random 0–2 s, reconnects and sends `room:resume`. Each resume rotates the token, and the app keeps the new one. A phone that wakes up reconnects at once.
- **Lost pushes:** if a deadline passes by 1.5 s with no new state, the app asks with `room:sync`.
- **Retries:** answers and votes are resent once after a reconnect (the server keeps the last one). Joins never are.
- **Origins:** the game must list the page's origin in `ALLOWED_ORIGINS`.

## Run it locally

`make up` serves the UI from its image at http://127.0.0.1:8080, behind the stack's nginx with the game ([compose/](../../compose/README.md)). To see a game without other people, have the bots join quick play: `docker compose -f compose/compose.yaml run --rm bots synthetic --game-mode quickplay --players 2`, after joining quick play in the browser.

While changing the UI, the Vite dev server reloads on every edit, against the same stack:

```bash
cd apps/web && npm ci && npm run dev    # http://localhost:5173, proxies /socket.io to the stack's nginx
```

The stack's game accepts `http://localhost:5173`. The dev server sends none of the image's headers, so a Content-Security-Policy problem shows only on the image.

## The image

`apps/web/Dockerfile` ([ADR 0027](../../docs/adr/0027-web-image-nginx-any-path.md)): `vite build` in the Node builder, then nginx-unprivileged serving `/srv/web` with [nginx.conf](nginx.conf).

- **How it runs:** nginx is PID 1, as uid 101, on a read-only root filesystem with `/tmp` writable (a tmpfs, or an emptyDir in Kubernetes), with one worker, listening on 8080. Its stop signal is SIGQUIT, nginx's graceful stop.
- **Any path prefix:** `/` and `/pr-12/` serve the same page, and `/pr-12/assets/<file>` the same files. `/pr-12` redirects to `/pr-12/`. Anything else is 404.
- **Caching and headers** ([ADR 0028](../../docs/adr/0028-web-caching-and-security-headers.md)):
  - hashed assets are cached for a year (`immutable`);
  - `index.html` is revalidated on every load (`no-cache`, then a 304 when unchanged);
  - every response carries a strict Content-Security-Policy (same origin only), `nosniff` and `no-referrer`;
  - text files are precompressed, and nginx sends the `.gz` copy to clients that accept gzip.
- **The contract:**

  | Path | Answers |
  |---|---|
  | `/healthz`, `/readyz` | 200 while nginx accepts connections. After SIGQUIT it closes its socket, so the probe fails. |
  | `/metrics` | Prometheus gauges from nginx's connection counters. 404 for requests through a proxy or the load balancer (`X-Forwarded-For`). |
  | `/version` | `{"version":"<git sha>","nginx":"1.31.7"}` |

  Access logs are JSON lines on stdout, with the version. nginx's own messages go to stderr in its plain format.

```bash
make web-image-smoke    # build rarebit-web:dev and check all of the above, run non-root and read-only
```

## Build and test

```bash
make web    # npm ci (scripts disabled), tsc type check, unit tests, vite build to dist/
```

The unit tests cover the logic the screens rely on:
- where the app lives (base path, socket path, join links, room codes from links);
- the server's clock and the timer's squares;
- the state reducer (seating, a new phase, a new round forgetting the sent answer and votes, a late snapshot of another room, the rotated token, a lost room);
- the copy: a Hebrew message for every error code the game's README lists, and a mark and a word for every verdict.

The build is about 93 KB of JavaScript and 4 KB of CSS, gzipped, plus the font files a phone needs (each one a file, never inlined: ADR 0028).

Not covered yet: browser tests (Playwright, across OSes and browsers, come with the test arena).
