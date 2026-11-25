# 0027. Serve the web UI from its own nginx-unprivileged image, under any path prefix

- **Status:** accepted
- **Date:** 2026-11-25
- **Deciders:** platform owner

## Context

The web UI is one static build that works under any path prefix (ADR 0026). In the cluster it needs a pod of its own: the ALB routes requests but doesn't serve files.

Every service follows the runtime contract (CLAUDE.md → Rules, rule 7): `/healthz`, `/readyz` (false while draining), `/metrics`, `/version`, JSON logs, config validated at startup, a graceful stop, non-root, read-only root filesystem.

CLAUDE.md names nginx-unprivileged for the UI. Its stock image doesn't start on a read-only filesystem, for two reasons:
- nginx creates its temp directories under `/tmp` at boot;
- the image's entrypoint scripts rewrite files under `/etc/nginx`.

## Decision

- **Its own image** (`apps/web/Dockerfile`).
  - The Node builder (the game's digest) runs `vite build`.
  - The runtime is nginx-unprivileged 1.31.7 on Alpine, the same digest as the local stack's entry nginx, with our `nginx.conf`. The built files go in `/srv/web`.
  - The configuration and the files belong to root and are read-only to nginx. The base image gives `/etc/nginx` to nginx's user, so the build takes it back.
- **nginx itself is PID 1:** `ENTRYPOINT ["nginx", "-g", "daemon off;"]`, without the base image's entrypoint scripts.
  - It runs as uid 101 with `/tmp` as its only writable path (a tmpfs, an emptyDir in Kubernetes).
  - It runs one worker: the pod scales out, and `auto` would count the node's CPUs.
- **The stop signal is SIGQUIT**, nginx's graceful stop.
  - nginx stops taking connections at once, finishes the requests in flight within `worker_shutdown_timeout` (10 s), and exits 0.
  - On SIGTERM it would stop at once and cut transfers off.
- **Traffic leaves before nginx stops.** Because nginx refuses new connections the moment it gets the signal, the deployment holds the pod with a preStop sleep while the Service and the ALB drop it. The settings are in `apps/web/README.md` → Settings the deployment must get right. The game does the same with its drain delay.
- **The contract, answered by nginx:**
  - **`/healthz` and `/readyz`** return 200. The files are in the image, so there's no dependency to check. After the signal, the closed socket fails the probe.
  - **`/metrics`** is on its own port, **9113**, which the Service exposes for Prometheus and no Ingress ever routes.
    - Port 8080 answers `/metrics` with 404.
    - The output is Prometheus text built from nginx's connection counters (the `stub_status` variables). Request rates and latencies come from the load balancer.
  - **`/version`** returns the git SHA, which the build writes into an nginx include after checking it's 7 hex characters.
  - **Logs:** access logs are JSON lines on stdout, with the version and the path without its query string, since join links carry the room code.
  - **Configuration:** checked by `nginx -t` at build time, and again by nginx at start.
- **Any path prefix, with no configuration:**
  - regex locations serve `<any prefix>/assets/<file>` from `assets/`, and every path ending in `/` as `index.html`;
  - a prefix without its slash redirects to the slash, and everything else is 404;
  - prefix segments are plain names, and the asset name can't contain `/`;
  - the ingress decides which prefixes reach the pod.
- **Precompressed:** the build gzips every text file (`gzip -9 -n`), and `gzip_static` sends that copy to clients that accept gzip, so nginx does no compression work per request.
- **In the local stack:** a `web` service runs the image. The entry nginx sends `/` to it and `/socket.io/` to the game replicas, as the ALB will, so `make up` serves the game at `http://127.0.0.1:8080`. `make smoke` checks that `/` serves the UI.
- **`make web-image-smoke`** checks the contract:
  - the image, its permissions, and the endpoints;
  - the page and its assets at `/` and under a prefix;
  - caching (ADR 0028), security headers (ADR 0029), and compression;
  - the logs;
  - a graceful stop with a download in flight.

## Alternatives considered

| Option | Why not |
|---|---|
| Serve `dist/` from the entry nginx through a bind mount | Simplest locally, but nothing to deploy: in the cluster the ALB can't serve files, so the UI needs a pod either way. |
| A `BASE_PATH` variable, templated into the config at start (the image's envsubst scripts) | A writable `conf.d`, the entrypoint scripts back, and one more setting per environment, for something the request path already says. |
| `/metrics` on 8080, refused when the request carries `X-Forwarded-For` | It depends on every hop adding the header. A load balancer set to remove or preserve it would make `/metrics` public without any error. A port that's never routed can't leak that way. |
| A shell-less image (distroless with a tiny static server, or a hardened nginx from another vendor) | No shell would be better. But nginx-unprivileged is the one CLAUDE.md names, it's maintained by the nginx team, and a homemade static server would need its own caching, compression and HTTP semantics. |
| The `nginx-prometheus-exporter` sidecar for `/metrics` | Request counters too, but a second container in every web pod for numbers the ALB already reports. It can be added later in the chart without changing the image. |
| Keep the entrypoint scripts, with `/etc/nginx/conf.d` on a tmpfs | Scripts we don't need (IPv6 rewrite, envsubst, worker tuning) running before nginx on every start. |

## Consequences

- **Good:**
  - one image for every environment and every preview path;
  - the same contract as every other service, checked by the smoke test;
  - about 57 MB unpacked, mostly the base; the UI's files are 2.5 MB;
  - static files cost little CPU, so the web pods can stay small.
- **Bad / risks:**
  - **Two exceptions to rule 7's wording.**
    - The graceful stop is on SIGQUIT, not SIGTERM. Docker and Kubernetes send the image's stop signal, but anything that sends a literal SIGTERM cuts transfers off: `docker kill`, or a chart that overrides the stop signal.
    - nginx's own messages (startup, configuration errors) are plain text on stderr, not JSON. The log pipeline must accept them.
  - **The drain depends on the deployment.** Without the preStop sleep, a rolling deploy or a node drain refuses connections the load balancer still sends.
  - **The image has a shell** (BusyBox, from Alpine).
  - **`/metrics` has connection gauges only.** Request rates and latencies depend on the load balancer's metrics being collected.
  - **The server answers under any prefix.** A wrong ingress path shows the page with a socket path the game doesn't serve ("can't connect"); the runbook covers it.

## How we'll know it was right

- Previews come up under their prefix with no image or config change.
- Web pods restart and roll without refused connections or dropped downloads.
- The smoke test keeps catching contract breaks before a merge.
