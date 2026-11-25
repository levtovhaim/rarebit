# The bots image: the synthetic game (a CronJob in the cluster, `make smoke` locally), load tests
# and the chaos observer (Jobs). Build it from the repo root with `make bots-image` (needs
# BuildKit: the build context is limited by Dockerfile.dockerignore next to this file).
#
# The contract, checked by `make bots-image-smoke`:
#   - runs as a numeric non-root user, works on a read-only root filesystem, has no shell;
#   - Node runs the bots directly as PID 1, in exec form, so SIGTERM reaches them: no new games,
#     running ones finish, the summary is printed;
#   - `synthetic` is the default command; a Job's args pick another mode and its options;
#   - the word lists are in /data/categories (BOTS_WORDS_DIR), read-only;
#   - GIT_SHA goes into every log line as `version`;
#   - the built bots and their production dependencies only; no file is world-writable, setuid
#     or setgid;
#   - the image is at most 200 MB unpacked (the base is 178 MB, 150 MB of it the node binary).

# ---- Build stage: install, compile, keep only the production dependencies ---------------------

# Node 26.13.1 (the .mise.toml version) on Debian 13: this tag's build of 2026-11-11, as for the game.
FROM node:26.13.1-trixie-slim@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc AS build

# npm's update check would reach for the network in the offline steps below.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
WORKDIR /src/apps/bots

# The manifest, the lockfile and .npmrc (install scripts off) before the source, so this layer is
# reused until the dependencies change. npm ci installs exactly the lockfile, checking every
# package's integrity hash. This is the only step with network access.
COPY apps/bots/package.json apps/bots/package-lock.json apps/bots/.npmrc ./
RUN npm ci --no-fund --no-audit

COPY apps/bots/tsconfig.json apps/bots/tsconfig.build.json ./
COPY apps/bots/src/ src/
# The commit: 7 hex characters, with -dirty when the tree had uncommitted changes.
ARG GIT_SHA
# Compile, drop the dev dependencies and the empty scope folders npm leaves behind, and collect
# what the runtime needs in /out/app with fixed permissions (COPY keeps the build machine's file
# modes, and files on a Windows drive under WSL show up as 0777).
RUN --network=none { expr "$GIT_SHA" : '[0-9a-f]\{7\}$' >/dev/null \
        || expr "$GIT_SHA" : '[0-9a-f]\{7\}-dirty$' >/dev/null \
        || { echo "GIT_SHA must be 7 hex characters, optionally with -dirty; got '$GIT_SHA'" >&2; exit 1; }; } \
    && npm run build \
    && npm prune --omit=dev --no-fund --no-audit \
    && mkdir -p /out/app \
    && cp -r dist node_modules package.json /out/app/ \
    && find /out -type d -empty -delete \
    && chmod -R u=rwX,go=rX /out

# The word lists the scripted bots answer from, read-only. Last in this stage, so a content change
# rebuilds nothing else.
COPY data/categories/ /out/data/categories/
RUN find /out/data -type d -exec chmod 0555 {} + \
    && find /out/data -type f -exec chmod 0444 {} +

# ---- Runtime stage: Node, the built bots, their dependencies, the word lists ------------------

# distroless nodejs26: Node 26.13.1 and the libraries it loads; no shell, no npm (ADR 0022).
# This build: 2026-11-12, as for the game.
FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:1d736cf8b5716c07a245301f92717143215d248fd55771ee1936ef4b3302e531

ARG GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/levtovhaim/rarebit" \
      org.opencontainers.image.description="Rarebit bots: the synthetic game, load tests and the chaos observer" \
      org.opencontainers.image.revision="${GIT_SHA}"

WORKDIR /app
COPY --from=build /out/app/ /app/
COPY --from=build /out/data/ /data/

ENV GIT_SHA=${GIT_SHA} \
    BOTS_WORDS_DIR=/data/categories
# Numeric, so Kubernetes can check runAsNonRoot without looking the name up.
USER 65532:65532
# The program in ENTRYPOINT, the mode in CMD: a Job's `args:` replace only the mode and options
# (`args: ["observe", "--rooms", "10"]`), and the image alone runs the synthetic game. Exec form:
# Node is PID 1 and gets SIGTERM itself.
ENTRYPOINT ["/nodejs/bin/node", "/app/dist/main.js"]
CMD ["synthetic"]
