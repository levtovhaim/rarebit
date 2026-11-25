# 0025. Ship the bots as an image, and run `make smoke` from it

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner
- **Supersedes:** the `make smoke` bullet of ADR 0024 (the bots ran from the host)

## Context

ADR 0024 ran `make smoke` from the host (`node apps/bots/dist/main.js`), because there was no bots image. That made the local stack need Node and a `make bots` first, and the synthetic game, which will run in the cluster as a CronJob, had nothing to run.

## Decision

- **A bots image,** built like the game's (ADR 0022): `node:26.13.1-trixie-slim` to build, `distroless/nodejs26` to run, numeric non-root user, read-only, no shell, Node as PID 1.
- **The word lists in the image,** at `/data/categories` (`BOTS_WORDS_DIR`), as the validator ships them (ADR 0018). The scripted bots answer from the lists the validator they test loads.
- **`ENTRYPOINT` is the program, `CMD` the mode:** `ENTRYPOINT ["/nodejs/bin/node", "/app/dist/main.js"]`, `CMD ["synthetic"]`. The image alone runs the synthetic game; a Job's `args:` choose another mode and its options without repeating the program.
- **`make smoke` runs the image** in the compose stack (`docker compose run --rm bots synthetic`), through nginx like any player, in the `tools` profile so `make up` doesn't start it. `make smoke` needs only Docker.
- **`make bots-image-smoke`** checks the contract without a game server: the image, the word lists, the default command, and SIGTERM handling.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep `make smoke` on the host | Needs Node and `make bots` on every machine, and leaves the CronJob without an image. |
| One Dockerfile with targets for the game and the bots | Less duplication, but one build context and one rebuild for two images that change independently. |
| No default `CMD` (the mode is required) | Every run would have to repeat it; `synthetic` is the mode that runs unattended, so it's the default. A bad call still exits 2 with the problem listed. |
| Word lists from a volume or the validator's API | A volume is one more thing to mount in every Job; an API the validator doesn't have. Baking them in keeps a run self-contained. |

## Consequences

- **Good:**
  - `make smoke` and the drills need only Docker;
  - the synthetic CronJob has its image;
  - the bots image is the same shape as the game's, so the chart and the pipeline treat them alike.
- **Bad / risks:**
  - the word lists are in two images (validator and bots). A content change rebuilds both; if only the validator is rebuilt, a round in a new category gets made-up answers from the bots (the room votes on them), and the game still passes;
  - about 180 MB unpacked, almost all of it the Node binary.

## How we'll know it was right

`make smoke` passes on a machine with only Docker, and the CronJob runs the image with nothing but `BOTS_URL`, `BOTS_ORIGIN` and its schedule.
