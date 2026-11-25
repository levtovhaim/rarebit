# 0022. Run the game image on distroless Node.js, with Node itself as PID 1

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The game server (ADR 0019) needs an image that meets the runtime contract (CLAUDE.md → Rules, rule 7): non-root, a read-only root filesystem, and a graceful drain on SIGTERM. The drain matters more here than for most services: players hold WebSockets open for whole games, and the server must tell them to reconnect elsewhere (`server:draining`) before it goes.

The server is plain JavaScript once compiled: no native add-ons (install scripts are off in `apps/game/.npmrc`), so it needs Node and its `node_modules`, nothing else. The validator image (ADR 0017) set the pattern: a build stage with the toolchain, a distroless runtime, an allowlisted build context, and a smoke test of the contract.

## Decision

- **Runtime:** `gcr.io/distroless/nodejs26-debian13:nonroot`. It holds Node (26.13.1, the `.mise.toml` version) and the libraries it loads; no shell, no npm, no package manager.
- **Build:** `node:26.13.1-trixie-slim` runs `npm ci` (the only step with network access; every package's integrity hash is checked), the `tsc` build, then `npm prune --omit=dev`. The runtime gets `dist/`, the production `node_modules/` and `package.json` (for `"type": "module"`), owned by root and read-only to the server.
- **Start:** `ENTRYPOINT ["/nodejs/bin/node", "/app/dist/main.js"]`, in exec form, with no `CMD`. Node is PID 1 and receives SIGTERM itself. Arguments from `docker run` or Kubernetes `args:` can't replace the script; replacing the command takes an explicit `command:`.
- **User:** numeric, `65532:65532`.
- **A command health check:** `dist/check-ready.js` (exit 0 when `/readyz` is 200) for health checks that run a command, such as docker compose's; Kubernetes probes `/readyz` over HTTP.
- **Pins:** both base images by digest, chosen by artifact age like the validator's: the `node` tag's build of 2026-11-11 (from the official images' published history) and the distroless build uploaded 2026-11-12.

## Alternatives considered

| Option | Why not |
|---|---|
| `node:26-trixie-slim` as the runtime | The exact Node patch is ours to choose, but it ships npm, corepack and a shell: about twice the size of what we need, and a shell for anyone who gets code execution in the pod. |
| Starting with `npm start` (on an image with npm) | Measured: npm runs `sh -c node dist/main.js` as a child; on SIGTERM the shell died from the signal, the server never started its drain, and the container exited 1 in about a second, so players got no `server:draining`. npm also checked the registry for its own updates at startup. |
| A shell-form `ENTRYPOINT` or `CMD` | Needs `/bin/sh`; on distroless the container doesn't start (`exec: "/bin/sh": ... no such file or directory`, exit 127). |
| Bundling the server into one file (esbuild) | No `node_modules` in the image, but another build tool, and dynamic and optional `require`s in the WebSocket stack make bundles fragile. The 38 MB it would save is small next to the 150 MB Node binary. |
| Alpine (musl) | Node's official builds target glibc; musl builds are community-maintained, and the validator is already on Debian 13. |

## Consequences

- **Good:**
  - the drain works as designed: measured with the image, SIGTERM → drained → exit 0 in about 2 s with a 1 s drain delay;
  - one process in the container, no shell to exec into, no package manager;
  - the same shape as the validator image, so the chart and the pipeline treat both alike.
- **Bad / risks:**
  - about 201 MB unpacked, 150 MB of it the Node binary itself;
  - debugging needs an ephemeral debug container (`kubectl debug`), since there's no shell;
  - distroless rebuilds Node on its own schedule: moving to a new Node patch means a new distroless digest that carries it, checked with `docker run <image> --version` against `.mise.toml`;
  - `@types/*` packages that `socket.io` lists as dependencies ship in the image (about 3 MB, never loaded).

## How we'll know it was right

Rolling deploys and pod kills in the test arena never drop a game without `server:draining`, and the image smoke test keeps passing as dependencies change.
