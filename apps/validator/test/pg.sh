# shellcheck shell=bash
# Throwaway Postgres containers for the validator's tests. Sourced by the Makefile
# (validator-integration) and by image-smoke.sh, so both start it the same way.
#
#   pg_start <name> <image> [network]
#
# Starts a container with a random password and waits until it accepts TCP connections. With a
# network, other containers reach it as <name>:5432; without one, it's published on a random
# loopback port (pg_port prints it). Sets PG_PASSWORD. Removing the container is the caller's
# job (docker rm -f <name>, usually in a trap).

pg_start() {
  local name="$1" image="$2" network="${3:-}"
  PG_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  # The password goes by name (-e VAR), so it stays out of docker's command line.
  local args=(-d --name "$name" -e POSTGRES_PASSWORD)
  if [ -n "$network" ]; then
    args+=(--network "$network")
  else
    args+=(-p 127.0.0.1::5432)
  fi
  POSTGRES_PASSWORD="$PG_PASSWORD" docker run "${args[@]}" "$image" >/dev/null
  # TCP, not the socket: during its first start the image runs a socket-only server, then restarts.
  for _ in $(seq 60); do
    docker exec "$name" pg_isready -q -h 127.0.0.1 -U postgres && return 0
    sleep 1
  done
  echo "Postgres didn't start" >&2
  return 1
}

pg_port() {
  docker port "$1" 5432/tcp | head -n1 | sed 's/.*://'
}
