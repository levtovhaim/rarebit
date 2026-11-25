# 0027. Serve the web UI from its own nginx-unprivileged image, under any path prefix

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The web UI is one static build that works under any path prefix (ADR 0026). In the cluster it needs a pod of its own: the ALB routes requests but doesn't serve files. Every service follows the runtime contract (CLAUDE.md → Rules, rule 7): `/healthz`, `/readyz` (false while draining), `/metrics`, `/version`, JSON logs, config validated at startup, a graceful stop, non-root, read-only root filesystem. CLAUDE.md names nginx-unprivileged for the UI. Its stock image doesn't start on a read-only filesystem: nginx creates its temp directories under `/tmp` at boot, and the image's entrypoint scripts rewrite files under `/etc/nginx`.

## Decision

- **Its own image** (`apps/web/Dockerfile`): the Node builder (the game's digest) runs `vite build`. The runtime is nginx-unprivileged 1.31.7 on Alpine, the same digest as the local stack's entry nginx, with our `nginx.conf`. The built files go in `/srv/web`, owned by root.
- **nginx itself is PID 1:** `ENTRYPOINT ["nginx", "-g", "daemon off;"]`, without the base image's entrypoint scripts. It runs as uid 101 with `/tmp` as its only writable path (a tmpfs, an emptyDir in Kubernetes), and one worker: the pod scales out, and `auto` would count the node's CPUs.
- **The stop signal is SIGQUIT:** nginx closes its listening socket, finishes the requests in flight, and exits 0. On SIGTERM it would stop at once and cut transfers off.
- **The contract, answered by nginx:**
  - `/healthz` and `/readyz` return 200. The files are in the image, so there's no dependency to check. Once SIGQUIT closes the listening socket, the probe fails: not ready while draining.
  - `/metrics` is Prometheus text built from nginx's connection counters (the `stub_status` variables). It answers only scrapes that reach the pod directly: a request carrying `X-Forwarded-For`, which came through a proxy or the load balancer, gets 404. Request rates and latencies come from the load balancer.
  - `/version` returns the git SHA, which the build writes into an nginx include after checking it's 7 hex characters.
  - Access logs are JSON lines on stdout, with the version. nginx's own messages stay in its plain format on stderr.
  - The configuration is checked by `nginx -t` at build time, and again by nginx at start.
- **Any path prefix, with no configuration:** regex locations serve `<any prefix>/assets/<file>` from `assets/` and every path ending in `/` as `index.html`. A prefix without its slash redirects to the slash, and everything else is 404. Prefix segments are plain names, and the asset name can't contain `/`. The ingress decides which prefixes reach the pod.
- **Precompressed:** the build gzips every text file (`gzip -9 -n`), and `gzip_static` sends that copy to clients that accept gzip, so nginx does no compression work per request.
- **In the local stack,** a `web` service runs the image. The entry nginx sends `/` to it and `/socket.io/` to the game replicas, as the ALB will, so `make up` serves the game at `http://127.0.0.1:8080`.
- **`make web-image-smoke`** checks the contract: the image, the endpoints, the page and its assets at `/` and under a prefix, caching and security headers (ADR 0028), compression, logs, the graceful stop.

## Alternatives considered

| Option | Why not |
|---|---|
| Serve `dist/` from the entry nginx through a bind mount | Simplest locally, but nothing to deploy: in the cluster the ALB can't serve files, so the UI needs a pod either way. |
| A `BASE_PATH` variable, templated into the config at start (the image's envsubst scripts) | A writable `conf.d`, the entrypoint scripts back, and one more setting per environment, for something the request path already says. |
| A shell-less image (distroless with a tiny static server, or a hardened nginx from another vendor) | No shell would be better. But nginx-unprivileged is the one CLAUDE.md names, it's maintained by the nginx team, and a homemade static server would need its own caching, compression and HTTP semantics. |
| The `nginx-prometheus-exporter` sidecar for `/metrics` | Request counters too, but a second container in every web pod for numbers the ALB already reports. It can be added later in the chart without changing the image. |
| Keep the entrypoint scripts, with `/etc/nginx/conf.d` on a tmpfs | Scripts we don't need (IPv6 rewrite, envsubst, worker tuning) running before nginx on every start. |

## Consequences

- **Good:**
  - one image for every environment and every preview path;
  - the same contract as every other service, checked by the smoke test;
  - about 56 MB unpacked, mostly the base; the UI's files are 2.5 MB;
  - static files cost little CPU, so the web pods can stay small.
- **Bad / risks:**
  - the image has a shell (BusyBox, from Alpine);
  - `/metrics` has connection gauges only; request rates and latencies depend on the load balancer's metrics being collected;
  - the server answers under any prefix, so a wrong ingress path shows the page with a socket path the game doesn't serve ("can't connect"); the runbook covers it.

## How we'll know it was right

Previews come up under their prefix with no image or config change, web pods restart and roll without dropped downloads, and the smoke test keeps catching contract breaks before a merge.
