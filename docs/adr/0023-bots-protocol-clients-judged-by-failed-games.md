# 0023. Build the bots as real protocol clients with a strategy hook, and judge runs by failed games

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

One tool has to serve several jobs: the synthetic game (black-box monitoring: is the game working, seen from outside?), load tests, the chaos observer (did killing pods fail any game?), and later the test arena's personas and bot swarm. Each asks the same question in a different shape: do games finish correctly?

The game's guarantees under failure (ADRs 0019–0021) only hold if clients do their part (ADR 0020): reconnect with jitter, resume with the newest token, ask with `room:sync` when a push is lost, leave a draining server. A load tool that only opens sockets and sends events would measure the server, not the experience.

## Decision

- **Each bot is a full client** of the protocol as ADR 0020 specifies it: WebSocket only; on a dropped connection or `server:draining`, a random 0–2 s wait, then the next URL and `room:resume`; the deadline watchdog; the server's clock from `serverNow`. Only idempotent events (answers, votes, sync) are resent after a reconnect; joins never are. The room snapshot is the truth after a reconnect: a round whose `round:start` was missed still gets its answer.
- **The persona hook:** how a bot plays is a `Strategy` (a nickname, an answer per round, a vote per answer), sync or async. The client and the game flow never choose an answer or a vote. Personas, including model-backed ones, are new strategies.
- **The verdict is the failed game:** a game fails when it doesn't end in time, stalls past a deadline by more than a lease plus a sweep, loses a bot (no reconnect, a refused resume, or still no end for it a reconnect's time after the others saw one), gets an error code a correct client never gets, or ends with winners the bots disagree on or scores that aren't the sum of the rounds. A run passes with at most `--max-failed` failed games. Latency percentiles and counters are reported, not judged.
- **Modes:** `synthetic` (one game, exit 0/1), `load` (rooms × games), `observe` (games back to back for a duration: the chaos observer). Load and observe use private rooms only, so they never mix with each other or with real players.
- **Output:** JSON lines (each game, then a summary) and the exit code. No metrics endpoint: a Job's exit status is what the platform alerts on, and its logs hold the detail.
- **Tested against the real game server:** the integration tests run the built game (two processes on one Redis) and play through a SIGKILL, a drain and the loss of every server.

## Alternatives considered

| Option | Why not |
|---|---|
| A generic load tool (k6, Artillery) with a Socket.IO plugin | Fine for socket counts and event rates, but the game flow (seat, answer from the snapshot, vote, resume with a rotated token) and the verdict on each game would be a script in another language and runtime, outside the repo's tests. |
| Bots that share the game's TypeScript types (a shared package) | Couples the two builds and images. The protocol is small; the bots keep their own copy, and the integration tests catch any drift. |
| Judging runs by error rate or latency | A pod kill makes some requests slow or fail by design; what players lose is a game. Percentiles are reported for load tests to read. |
| Synthetic games through quick play | In a shared environment the bots would join real players' rooms. |
| A metrics endpoint (or Pushgateway) on the bots | A one-shot Job's result is its exit code; Kubernetes and the monitoring stack already watch Job status. Revisit if load tests need live graphs. |

## Consequences

- **Good:**
  - the synthetic game fails exactly when a player's game would, for the same reasons, with a reason that points at the right runbook;
  - chaos runs have a clear pass/fail: zero failed games;
  - a persona is one new `Strategy`; nothing else changes.
- **Bad / risks:**
  - the bots' copy of the protocol can drift from the server's; only the integration tests catch it;
  - load tests from a few addresses need the target's `MAX_CONNECTIONS_PER_IP` raised;
  - the scripted bots answer from the same word lists the validator loads, so they can't find validator bugs about words that aren't listed.
- **Follow-ups:**
  - the bots' image and the `make smoke` stack;
  - a CronJob running `synthetic` against each environment, alerting on failed Jobs;
  - the arena's personas and the swarm.

## How we'll know it was right

Pod kills during load show zero failed games, a deliberate outage fails the synthetic game with a reason that names it, and the first persona lands without changing the client.
