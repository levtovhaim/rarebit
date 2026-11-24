# The validator image: `validator serve` (the Deployment) and `validator migrate` (the Job).
# Build it from the repo root with `make validator-image`; the build context is limited by
# Dockerfile.dockerignore next to this file.
#
# The contract, checked by `make validator-image-smoke`:
#   - runs as a non-root user, works on a read-only root filesystem, has no shell;
#   - /validator is the entrypoint, in exec form, so it receives SIGTERM as PID 1; `serve` is
#     the default command;
#   - `validator version` prints the git SHA passed in the GIT_SHA build arg;
#   - the word lists are in /data/categories (the default VALIDATOR_DATA_DIR is /data), and no
#     file in the image is world-writable;
#   - the image is at most 45 MB unpacked.

# ---- Build stage: the C++ library, then the Go binary linked against it ----------------------

# Go 1.27.4 on Debian 13. The runtime image is Debian 13 too, so the glibc and libstdc++ the
# binary links against at build time are the ones it finds at runtime.
FROM golang:1.27.4-trixie@sha256:430985542100b871e108ccc00e8dcc5eef08ca14ee5825e98ebf563d8ffec4ee AS build

# gcc and g++ come with the image; CMake and Ninja build the library. Pinned to the versions
# Debian 13 ships (hadolint DL3008): if Debian replaces one, the build fails here and the pin
# gets bumped on purpose instead of drifting.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake=3.31.6-2 ninja-build=1.12.1-1 \
    && rm -rf /var/lib/apt/lists/*

# The library: the same Release build as `make hebrew-lib`, installed into /opt/hn.
WORKDIR /src
COPY native/ native/
RUN cmake -S native -B /tmp/hn-build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib \
    && cmake --build /tmp/hn-build \
    && cmake --install /tmp/hn-build --prefix /opt/hn

# Modules before the source, so this layer is reused until go.mod or go.sum changes.
WORKDIR /src/apps/validator
COPY apps/validator/go.mod apps/validator/go.sum ./
RUN go mod download

COPY apps/validator/ ./
ARG GIT_SHA
ENV CGO_ENABLED=1 CGO_CFLAGS=-I/opt/hn/include CGO_LDFLAGS=-L/opt/hn/lib
RUN go build -trimpath -ldflags "-s -w -X main.version=${GIT_SHA}" -o /out/validator ./cmd/validator

# The word lists, with fixed permissions: COPY keeps the build machine's file modes, and files on
# a Windows drive under WSL show up as 0777. Last in this stage, so a data change rebuilds nothing else.
COPY data/categories/ /out/data/categories/
RUN find /out/data -type d -exec chmod 0555 {} + \
    && find /out/data -type f -exec chmod 0444 {} +

# ---- Runtime stage: the binary, the word lists, nothing else ---------------------------------

# distroless cc: glibc, libstdc++ and CA certificates; no shell, no package manager.
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:532c7a94f9e96ba9db75eb9388f4227751131c7cb0a411d1a8521af4096135de

ARG GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/levtovhaim/rarebit" \
      org.opencontainers.image.description="Rarebit validator: checks answers against the word lists in Postgres" \
      org.opencontainers.image.revision="${GIT_SHA}"

COPY --from=build /out/validator /validator
COPY --from=build /out/data/ /data/

# Numeric, so Kubernetes can check runAsNonRoot without looking the name up.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/validator"]
CMD ["serve"]
