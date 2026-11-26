# The web UI image: the built UI as static files, served by nginx. Build it from the repo root
# with `make web-image` (needs BuildKit: the build context is limited by Dockerfile.dockerignore
# next to this file).
#
# The contract, checked by `make web-image-smoke`:
#   - runs as a numeric non-root user and works on a read-only root filesystem with a writable
#     /tmp (a tmpfs, or an emptyDir in Kubernetes);
#   - nginx itself is PID 1 (not the base image's entrypoint scripts, which rewrite files under
#     /etc/nginx), and stops gracefully on the image's stop signal, SIGQUIT;
#   - serves the UI at / and under any path prefix on 8080, with the runtime contract (/healthz,
#     /readyz, /version there, /metrics on 9113) and JSON access logs; /version reports the GIT_SHA
#     build arg;
#   - holds the built files only (no sources, no Node), precompressed; the configuration and the
#     files are root's and read-only to nginx; nothing in the image is world-writable, setuid or
#     setgid.
#
# The base has a shell (BusyBox, from Alpine): there's no shell-less nginx-unprivileged image.

# ---- Build stage: install, type-check, build, precompress ---------------------------------------

# Node 26.13.1 (the .mise.toml version) on Debian 13: this tag's build of 2026-11-11, the same
# digest as the game's builder.
FROM node:26.13.1-trixie-slim@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc AS build

# npm's update check would reach for the network in the offline step below.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
WORKDIR /src/apps/web

# The manifest, the lockfile and .npmrc (install scripts off) before the source, so this layer is
# reused until the dependencies change. npm ci installs exactly the lockfile, checking every
# package's integrity hash. This is the only step with network access.
COPY apps/web/package.json apps/web/package-lock.json apps/web/.npmrc ./
RUN npm ci --no-fund --no-audit

COPY apps/web/tsconfig.json apps/web/vite.config.ts apps/web/index.html ./
COPY apps/web/src/ src/
# The commit: 7 hex characters, with -dirty when the tree had uncommitted changes. Checked
# before it goes into nginx's configuration.
ARG GIT_SHA
# Type-check and build (npm run build), then:
#   - gzip every text file next to the original (-n: no name or time inside, so the same input
#     gives the same bytes); fonts are compressed already;
#   - write the version into an nginx include ($app_version);
#   - collect it all in /out with fixed permissions: COPY keeps the build machine's file modes,
#     and files on a Windows drive under WSL show up as 0777.
RUN --network=none { expr "$GIT_SHA" : '[0-9a-f]\{7\}$' >/dev/null \
        || expr "$GIT_SHA" : '[0-9a-f]\{7\}-dirty$' >/dev/null \
        || { echo "GIT_SHA must be 7 hex characters, optionally with -dirty; got '$GIT_SHA'" >&2; exit 1; }; } \
    && npm run build \
    && find dist -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.map' -o -name '*.svg' -o -name '*.json' \) \
        -exec gzip -9 -k -n {} + \
    && mkdir -p /out/web \
    && cp -r dist/. /out/web/ \
    && printf "map \$host \$app_version {\n  default \"%s\";\n}\n" "$GIT_SHA" > /out/rarebit-version.conf \
    && chmod -R u=rwX,go=rX /out

# ---- Runtime stage: nginx and the built files -----------------------------------------------------

# nginx 1.31.7 on Alpine 3.24, the unprivileged build (uid 101, port 8080, temp paths in /tmp):
# the same digest as the local stack's nginx (compose/compose.yaml).
FROM nginxinc/nginx-unprivileged:1.31.7-alpine3.24@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e

ARG GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/levtovhaim/rarebit" \
      org.opencontainers.image.description="Rarebit web UI: the game on a phone, in Hebrew, served by nginx" \
      org.opencontainers.image.revision="${GIT_SHA}"

COPY --chmod=0644 apps/web/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /out/rarebit-version.conf /etc/nginx/rarebit-version.conf
COPY --from=build /out/web/ /srv/web/
# The base image gives /etc/nginx to nginx's user (owner 101, group-writable), so it can run
# under any uid and rewrite its config at start. This image runs nginx directly and never
# rewrites it: the configuration and the files belong to root and are read-only to nginx, even
# where the root filesystem isn't read-only.
USER 0:0
RUN --network=none chown -R root:root /etc/nginx /srv/web && chmod -R go-w /etc/nginx /srv/web

# Numeric, so Kubernetes can check runAsNonRoot without looking the name up. The base image's
# user already is 101; stated here so the contract doesn't depend on the base.
USER 101:101
# A broken configuration fails the build, not the first start. -t creates nginx's temp
# directories under /tmp; they're removed so the image doesn't carry them.
RUN --network=none nginx -t -q && rm -rf /tmp/client_body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi

# 8080: the UI and the probes. 9113: /metrics, for Prometheus only (never in the Ingress).
EXPOSE 8080 9113
# nginx's graceful stop: close the listening socket, finish the requests in flight, exit. (On
# SIGTERM nginx stops at once and cuts transfers off.) Kubernetes and docker stop send the image's
# stop signal. The base image sets it too; stated here for the same reason as USER.
STOPSIGNAL SIGQUIT
# nginx itself, in the foreground, as PID 1, in exec form.
ENTRYPOINT ["nginx", "-g", "daemon off;"]
