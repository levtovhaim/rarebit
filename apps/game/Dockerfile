# The game server image. Build it from the repo root with `make game-image` (needs BuildKit: the
# build context is limited by Dockerfile.dockerignore next to this file).
#
# The contract, checked by `make game-image-smoke`:
#   - runs as a numeric non-root user, works on a read-only root filesystem, has no shell;
#   - Node runs the server directly as PID 1, in exec form (no npm or shell in between), so the
#     server itself gets SIGTERM and drains;
#   - /version reports the git SHA passed in the GIT_SHA build arg;
#   - holds the built server and its production dependencies only; no file is world-writable,
#     setuid or setgid;
#   - the image is at most 230 MB unpacked (the base is 178 MB, 150 MB of it the node binary;
#     the server and its dependencies add about 38 MB).

# ---- Build stage: install, compile, keep only the production dependencies ---------------------

# Node 26.13.1 (the .mise.toml version) on Debian 13: this tag's build of 2026-11-11.
FROM node:26.13.1-trixie-slim@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc AS build

# npm's update check would reach for the network in the offline steps below.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
WORKDIR /src/apps/game

# The manifest, the lockfile and .npmrc (install scripts off) before the source, so this layer is
# reused until the dependencies change. npm ci installs exactly the lockfile, checking every
# package's integrity hash. This is the only step with network access.
COPY apps/game/package.json apps/game/package-lock.json apps/game/.npmrc ./
RUN npm ci --no-fund --no-audit

COPY apps/game/tsconfig.json apps/game/tsconfig.build.json ./
COPY apps/game/src/ src/
# The commit: 7 hex characters, with -dirty when the tree had uncommitted changes.
ARG GIT_SHA
# Compile, drop the dev dependencies (TypeScript, vitest, the test client) and the empty scope
# folders npm leaves behind, and collect what the runtime needs in /out with fixed permissions:
# COPY keeps the build machine's file modes, and files on a Windows drive under WSL show up as
# 0777. (@types/node and friends stay: socket.io and engine.io list them as dependencies.)
RUN --network=none { expr "$GIT_SHA" : '[0-9a-f]\{7\}$' >/dev/null \
        || expr "$GIT_SHA" : '[0-9a-f]\{7\}-dirty$' >/dev/null \
        || { echo "GIT_SHA must be 7 hex characters, optionally with -dirty; got '$GIT_SHA'" >&2; exit 1; }; } \
    && npm run build \
    && npm prune --omit=dev --no-fund --no-audit \
    && mkdir /out \
    && cp -r dist node_modules package.json /out/ \
    && find /out -type d -empty -delete \
    && chmod -R u=rwX,go=rX /out

# ---- Runtime stage: Node, the built server, its production dependencies ---------------------

# distroless nodejs26: Node 26.13.1 and the libraries it loads (glibc, libstdc++, OpenSSL, CA
# certificates, tzdata); no shell, no npm, no package manager. Its entrypoint is
# /nodejs/bin/node; the nonroot variant's user is 65532. This build: 2026-11-12.
FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:1d736cf8b5716c07a245301f92717143215d248fd55771ee1936ef4b3302e531

ARG GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/levtovhaim/rarebit" \
      org.opencontainers.image.description="Rarebit game server: rooms, rounds and scoring over Socket.IO, state in Redis" \
      org.opencontainers.image.revision="${GIT_SHA}"

WORKDIR /app
# dist/ (the compiled server), node_modules/ (production dependencies only) and package.json,
# whose "type": "module" makes Node load dist/*.js as ES modules. Owned by root and not writable
# by the server's user, even where the root filesystem isn't read-only.
COPY --from=build /out/ /app/

# What /version reports. Everything else comes from the deployment (apps/game/README.md →
# Configuration) and is checked at startup.
ENV GIT_SHA=${GIT_SHA}
# Numeric, so Kubernetes can check runAsNonRoot without looking the name up. The base image's
# user already is 65532; stated here so the contract doesn't depend on the base.
USER 65532:65532
EXPOSE 8080
# The whole command, in exec form: Node is PID 1 and receives SIGTERM itself (no npm or shell to
# forward it), and the server's handler drains. ENTRYPOINT rather than CMD, so arguments given
# to `docker run` or Kubernetes `args:` can't replace the script; overriding the command takes an
# explicit `command:`. Source maps are off: the logs carry error messages, not stacks; turn them
# on for debugging with NODE_OPTIONS=--enable-source-maps, no rebuild needed.
ENTRYPOINT ["/nodejs/bin/node", "/app/dist/main.js"]
