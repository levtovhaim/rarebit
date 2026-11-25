# 0026. Build the web UI as one static bundle that renders from the room snapshot

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

Players play on their phones, in Hebrew, often on weak connections, and through pod restarts and drains (ADRs 0019–0021). Every pull request will get a preview environment, possibly under a path prefix (`/pr-12/`). The UI must be cheap to serve, survive reconnects without losing the player's place, and run unchanged at any path.

## Decision

- **React + Vite, built to static files** (CLAUDE.md → Architecture), served by nginx-unprivileged. No server-side rendering: there's nothing to render before the player has a connection.
- **One build for every path:** relative asset URLs (`base: "./"`), and the Socket.IO path derived from the page's own path (`<prefix>socket.io`). A preview at `/pr-12/` needs no rebuild and no runtime config; the game's `SOCKET_PATH` matches the prefix.
- **The snapshot is the state:** every screen renders from the latest `room:state`. A small reducer adds only what the server doesn't keep for this player (the connection, the answer sent, the votes cast) and drops it when a new round starts. No router: the room's phase picks the screen.
- **A protocol client like the bots:** WebSocket only; 0–2 s jitter, resume with the rotated token, the 1.5 s watchdog, leaving on `server:draining`; resend only idempotent actions. The seat survives a reload in `localStorage`.
- **Self-hosted fonts with real Hebrew glyphs** (Fontsource packages), split by script so a phone downloads only what it renders; no third-party font CDN.
- **Few dependencies:** React, `socket.io-client`, a QR encoder with no dependencies (`uqr`), the fonts. No state library, no CSS framework.

## Alternatives considered

| Option | Why not |
|---|---|
| Next.js (or any SSR) | A server to run and scale for pages that show nothing until a WebSocket connects. |
| A build per preview with the prefix baked in (`base: "/pr-12/"`) | One image per preview path; relative URLs make one image work everywhere. |
| Runtime config (`config.js` written at container start) | Something to template on a read-only filesystem, for a value the page can read from its own URL. |
| A client state library (Redux, Zustand) and a router | The server's snapshot is the state and the phase is the route; a reducer of a few actions covers the rest. |
| Google Fonts from their CDN | A third-party request on every load, and one more origin to allow; the self-hosted files are cached with the app. |

## Consequences

- **Good:**
  - a reload, a dropped connection or a pod drain puts the player back where the room is, from one snapshot;
  - previews at any path from the same build;
  - static files: cacheable, no server to scale for the UI.
- **Bad / risks:**
  - the protocol is copied by hand (`src/protocol.ts`); a server change the UI misses shows up only in browser tests, which come with the test arena;
  - the seat in `localStorage` is per browser: a second tab shares it, and the server closes the older connection (ADR 0020).

## How we'll know it was right

Players resume through a drain without noticing, previews work under their prefix without a rebuild, and the bundle stays small (about 93 KB of JavaScript gzipped at the start).
