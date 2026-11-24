# The validator image: `validator serve` (the Deployment) and `validator migrate` (the Job).
# Build it from the repo root with `make validator-image` (needs BuildKit: the build context is
# limited by Dockerfile.dockerignore next to this file).
#
# The contract, checked by `make validator-image-smoke`:
#   - runs as a numeric non-root user, works on a read-only root filesystem, has no shell;
#   - /validator is the entrypoint, in exec form, so it receives SIGTERM as PID 1; `serve` is
#     the default command;
#   - `validator version` prints the git SHA passed in the GIT_SHA build arg;
#   - the word lists are in /data/categories (the default VALIDATOR_DATA_DIR is /data), and no
#     file in the image is world-writable, setuid or setgid;
#   - the image is at most 45 MB unpacked.

# ---- Build stage: the C++ library, then the Go binary linked against it ----------------------

# Go 1.27.4 on Debian 13. The runtime image is Debian 13 too, so the glibc and libstdc++ the
# binary links against at build time are the ones it finds at runtime.
FROM golang:1.27.4-trixie@sha256:f18c3d73a184fb0582828510722e723b63a93f7188d11dd223d9be6f6880e65d AS build

# gcc and g++ come with the image; CMake and Ninja build the library (Debian 13's versions,
# ADR 0017). Pinned to what Debian 13 ships (hadolint DL3008): if Debian replaces one, the build
# fails here and the pin gets bumped on purpose. Their dependencies come unpinned from Debian's
# signed repository; this is the builder only.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake=3.31.6-2 ninja-build=1.12.1-1 \
    && rm -rf /var/lib/apt/lists/*

# The library: the same Release build as `make hebrew-lib`, installed into /opt/hn. No network:
# the build must not fetch anything (tests, and so GoogleTest, are off).
WORKDIR /src
COPY native/ native/
RUN --network=none cmake -S native -B /tmp/hn-build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib \
    && cmake --build /tmp/hn-build \
    && cmake --install /tmp/hn-build --prefix /opt/hn

# Modules before the source, so this layer is reused until go.mod or go.sum changes. This is
# the only Go step with network access.
WORKDIR /src/apps/validator
COPY apps/validator/go.mod apps/validator/go.sum ./
RUN go mod download

COPY apps/validator/ ./
# The commit: 7 hex characters, with -dirty when the tree had uncommitted changes. Checked,
# because it goes into the linker flags.
ARG GIT_SHA
ENV CGO_ENABLED=1 CGO_CFLAGS=-I/opt/hn/include CGO_LDFLAGS=-L/opt/hn/lib
RUN --network=none { expr "$GIT_SHA" : '[0-9a-f]\{7\}$' >/dev/null \
        || expr "$GIT_SHA" : '[0-9a-f]\{7\}-dirty$' >/dev/null \
        || { echo "GIT_SHA must be 7 hex characters, optionally with -dirty; got '$GIT_SHA'" >&2; exit 1; }; } \
    && go build -trimpath -ldflags "-s -w -X main.version=${GIT_SHA}" -o /out/validator ./cmd/validator

# The word lists, with fixed permissions: COPY keeps the build machine's file modes, and files on
# a Windows drive under WSL show up as 0777. Last in this stage, so a data change rebuilds nothing
# else (ADR 0018).
COPY data/categories/ /out/data/categories/
RUN find /out/data -type d -exec chmod 0555 {} + \
    && find /out/data -type f -exec chmod 0444 {} +

# ---- Runtime stage: the binary, the word lists, nothing else ---------------------------------

# distroless cc: glibc and libstdc++ (which the binary loads), plus OpenSSL, zlib, zstd, libgomp,
# tzdata and CA certificates (which it doesn't); no shell, no package manager.
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:cb87acc574abe719b6e5c547384defa2f7b1f24af9605d3f618cf852495d8be2

ARG GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/levtovhaim/rarebit" \
      org.opencontainers.image.description="Rarebit validator: checks answers against the word lists in Postgres" \
      org.opencontainers.image.revision="${GIT_SHA}"

COPY --from=build /out/validator /validator
COPY --from=build /out/data/ /data/

# Always Go's own DNS resolver: it honors the connect deadlines; a glibc lookup blocks a thread
# and can't be cancelled.
ENV GODEBUG=netdns=go
# Numeric, so Kubernetes can check runAsNonRoot without looking the name up.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/validator"]
CMD ["serve"]
