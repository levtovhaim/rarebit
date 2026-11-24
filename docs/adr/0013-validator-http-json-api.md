# 0013. Serve validation as an HTTP/JSON API

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** platform owner

## Context

The game server (Node.js) asks the validator about each answer at the end of a round: a room of 6 players and 6 categories makes 36 checks within a second or two. The validator is an internal service: only the game and the bots call it, through a ClusterIP Service, and it's never exposed outside the cluster. Its protocol has to:
- be easy to call from Node.js, the Go bots and `curl`;
- share a port with the runtime endpoints every service has: `/healthz`, `/readyz`, `/metrics`, `/version` (CLAUDE.md → Rules, rule 7);
- tell the game clearly when to fall back to the room vote.

## Decision

- **Protocol:** HTTP/1.1 with JSON bodies, one answer per request: `POST /v1/validate` with `{category, letter, answer}`, answered with `valid`, `invalid` or `unknown`. The runtime endpoints use the same port.
- **Versioning:** the path carries the version. An incompatible change becomes `/v2`, and `/v1` keeps working while old game pods are still rolling out.
- **Errors:** a caller mistake (unknown category, a bad letter, a malformed or oversized body) is a 4xx with an error code. Failing to read the word lists is a 503. The game treats a 503, or no validator at all, like an `unknown` answer (the room votes), so a validator outage slows a round down but doesn't stop it.

## Alternatives considered

| Option | Why not |
|---|---|
| gRPC | Typed contracts and HTTP/2 multiplexing, but it needs generated code in Go and Node and gRPC health probes. Nothing here needs streaming or that throughput. |
| A batch endpoint (all of a round's answers in one call) | Fewer round trips, but a more complex contract before there's a measurement. Add it as `/v1/validate-batch` if load tests show the per-answer calls cost too much. |
| Errors as 200 with an error field | Hides failures from the HTTP metrics and from the load balancer; a 503 is what both the game and the monitoring understand. |

## Consequences

- **Good:**
  - debuggable with `curl`;
  - no generated code;
  - one port for the API and the probes;
  - the error classes map directly to the game's fallback.
- **Bad / risks:**
  - one HTTP request per answer;
  - JSON has no schema the compiler checks: the README documents the contract, and the game's client must match it.
- **Follow-ups:**
  - load-test the round-end burst (bots);
  - in the game: one retry on a connection error (the call is read-only), then the vote.

## How we'll know it was right

At the load-test target, round-end validation stays well within the game's answer-acknowledgement budget, and no game code has to parse anything beyond the documented fields. If the per-answer calls dominate, add the batch endpoint.
