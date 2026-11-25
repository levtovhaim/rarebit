# 0020. Speak to game clients in Socket.IO events with acknowledgements, resume tokens and server deadlines

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

Two kinds of clients speak to the game server: the web UI on phones, and the bots (load tests, synthetic monitoring, the arena's personas and swarm).
- Phones drop connections often: network switches, the screen locking.
- Game pods come and go (ADR 0019), so a client must be able to continue on another pod.
- The bots measure the protocol: how long an answer takes to be acknowledged, and whether a game finished.
- Every client is untrusted, cheaters included.

## Decision

- **Transport:** Socket.IO over WebSocket only (`transports: ["websocket"]`), so no long-polling fallback and no sticky sessions. Pings every 10 s keep idle connections alive through the load balancer.
- **Requests and replies:** every client event (`room:create`, `answer:submit`, `vote:cast`, ...) carries an acknowledgement callback. It gets `{ ok: true, ... }` or `{ ok: false, error: "<code>" }`, from a fixed list of codes. An event without a callback is ignored.
- **Pushes:** the server sends a full `room:state` snapshot after every change, plus specific events (`round:start`, `vote:start`, `round:results`, `game:end`). A client that missed one still catches up from the next snapshot, or asks with `room:sync`.
- **Resume:** joining returns a `playerId` and a random token. Redis keeps only the token's SHA-256. After any reconnect, to any pod, `room:resume` with both puts the player back in their room.
- **Time:** deadlines are epoch milliseconds on the server, sent with `serverNow`. Clients count down from what they received and never compare against their own clock. The server accepts an answer only before the deadline.
- **Draining:** a pod that is shutting down sends `server:draining` after its readiness has been failing for the drain delay. Clients reconnect and resume elsewhere.
- **Untrusted input:**
  - every payload is checked with a schema (zod);
  - each socket has a token-bucket rate limit (10 in a burst, 5 a second);
  - a frame is at most 16 KiB;
  - nicknames and answers are capped and filtered;
  - `ALLOWED_ORIGINS` restricts which pages may connect.

## Alternatives considered

| Option | Why not |
|---|---|
| Plain WebSockets with our own JSON framing | We'd reimplement acknowledgements, reconnection, rooms and the cross-pod broadcast (the Redis adapter). |
| HTTP for actions plus Server-Sent Events for pushes | Two channels to keep in sync, per-action TLS and auth overhead, and the timer pushes still need fan-out across pods. |
| Socket.IO with the long-polling fallback | Long-polling needs sticky sessions with several pods. Every browser we target has WebSocket. |
| Client-side timers | Cheating, clock skew and late answers would all be the client's call. The server owns the clock. |

## Consequences

- **Good:**
  - every action has an explicit outcome the bots can assert and time (`game_answer_ack_seconds`);
  - reconnecting to another pod is one event;
  - a lost push is recovered from the next snapshot.
- **Bad / risks:**
  - snapshots repeat data on every change: fine at 8 players per room, wasteful for much bigger rooms;
  - the protocol is defined in code and the README, not in a schema file that clients generate from. The web UI and the bots must follow the README.
- **Follow-ups:**
  - the web UI and the bots implement it (Phase 1);
  - the arena's cheater persona probes the rate limits and replays.

## How we'll know it was right

The bots' synthetic game passes through rolling deploys and pod kills, phones resume after locking without losing their game, and the cheater persona can't get an answer accepted after the deadline.
