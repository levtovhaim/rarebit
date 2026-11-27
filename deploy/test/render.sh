#!/usr/bin/env bash
# Tests for deploy/charts/service and every service's values in deploy/apps (make deploy; in CI, the
# deploy check). ADR 0045.
#   Part 1: helm lint, and every service renders and passes kubeconform (the Kubernetes schemas).
#   Part 2: what every rendered workload has (CLAUDE.md rule 7 and Conventions).
#   Part 3: each service's shutdown timing, against its README.
#   Part 4: the values schema refuses what the golden path doesn't allow.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
chart="$root/deploy/charts/service"
apps="$root/deploy/apps"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

bad() {
  fail=$((fail + 1))
  echo "FAIL: $*" >&2
}

# assert <name> <command...>: passes when the command succeeds
assert() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else bad "$name"; fi
}

for tool in helm kubeconform yq jq; do
  command -v "$tool" >/dev/null || { echo "render.sh: needs $tool (mise install)" >&2; exit 2; }
done

# What a render needs and git doesn't hold: the registry's host (it holds the account ID, ADR 0035)
# and an image tag (an environment's image-tags.yaml).
fake_registry=000000000000.dkr.ecr.eu-central-1.amazonaws.com
fake_tag="main-0000000@sha256:$(printf '0%.0s' $(seq 64))"

# render <service> [helm args...]: the service's manifests on stdout
render() {
  local svc=$1 sets=()
  shift
  [ -n "$(yq '.image.registry // ""' "$apps/$svc/values.yaml")" ] || sets+=(--set "image.registry=$fake_registry")
  [ -n "$(yq '.image.tag // ""' "$apps/$svc/values.yaml")" ] || sets+=(--set-string "image.tag=$fake_tag")
  helm template "$svc" "$chart" -f "$apps/$svc/values.yaml" "${sets[@]}" "$@"
}

# The catalog entry a service's labels come from: validator-migrate is the validator's.
catalog_of() { printf '%s/catalog/%s.yaml' "$root" "${1%-migrate}"; }

mapfile -t services < <(find "$apps" -mindepth 1 -maxdepth 1 -type d -printf '%f
' | sort)
[ "${#services[@]}" -gt 0 ] || { echo "render.sh: no services in deploy/apps" >&2; exit 2; }

# --- Part 1: lint, render, schemas -----------------------------------------------------------------
assert "helm lint --strict (with the game's values)" \
  helm lint --strict "$chart" -f "$apps/game/values.yaml" --set "image.registry=$fake_registry" --set-string "image.tag=$fake_tag"
rendered=()
for svc in "${services[@]}"; do
  if render "$svc" >"$tmp/$svc.yaml" 2>"$tmp/$svc.err"; then
    pass=$((pass + 1))
    rendered+=("$svc")
  else
    bad "$svc renders: $(grep -m1 -v '^$' "$tmp/$svc.err")"
    continue
  fi
  assert "$svc passes kubeconform" kubeconform -strict -summary -cache "${KUBECONFORM_CACHE:-$tmp}" "$tmp/$svc.yaml"
done

# --- Part 2: every workload --------------------------------------------------------------------------
pod='select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec'
for svc in "${rendered[@]}"; do
  f="$tmp/$svc.yaml"
  q() { yq ea "$1" "$f"; }
  cat="$(catalog_of "$svc")"
  assert "$svc: has a catalog entry" test -f "$cat"
  assert "$svc: one workload" test "$(q '[select(.kind == "Deployment" or .kind == "Job")] | length')" = 1
  assert "$svc: runs as non-root" test "$(q "$pod | .securityContext.runAsNonRoot")" = true
  assert "$svc: seccomp RuntimeDefault" test "$(q "$pod | .securityContext.seccompProfile.type")" = RuntimeDefault
  assert "$svc: no service account token" test "$(q "$pod | .automountServiceAccountToken")" = false
  assert "$svc: read-only root filesystem" test "$(q "$pod | .containers[0].securityContext.readOnlyRootFilesystem")" = true
  assert "$svc: no privilege escalation" test "$(q "$pod | .containers[0].securityContext.allowPrivilegeEscalation")" = false
  assert "$svc: drops every capability" test "$(q "$pod | .containers[0].securityContext.capabilities.drop | join(\",\")")" = ALL
  assert "$svc: requests CPU and memory, and limits memory" \
    test "$(q "$pod | .containers[0].resources | (.requests.cpu != null and .requests.memory != null and .limits.memory != null)")" = true
  assert "$svc: the image is pinned by digest" bash -c "[[ \"\$(yq ea '$pod | .containers[0].image' '$f')\" == *@sha256:* ]]"
  # Labels: CLAUDE.md → Conventions, the owner and tier from the catalog
  want_owner="$(yq '.spec.owner | sub("^user:"; "")' "$cat" 2>/dev/null)"
  want_tier="$(yq '.metadata.labels.tier' "$cat" 2>/dev/null)"
  for kind in "$(q 'select(.kind == "Deployment" or .kind == "Job") | .kind')" Service ServiceAccount Ingress; do
    [ "$(q "[select(.kind == \"$kind\")] | length")" = 0 ] && continue
    labels="$(q "select(.kind == \"$kind\") | .metadata.labels")"
    assert "$svc $kind: part-of rarebit" test "$(yq '.["app.kubernetes.io/part-of"]' <<<"$labels")" = rarebit
    assert "$svc $kind: name label" test "$(yq '.["app.kubernetes.io/name"]' <<<"$labels")" = "$svc"
    assert "$svc $kind: owner $want_owner (catalog)" test "$(yq '.owner' <<<"$labels")" = "$want_owner"
    assert "$svc $kind: tier $want_tier (catalog)" test "$(yq '.tier' <<<"$labels")" = "$want_tier"
  done
  assert "$svc: pod labels carry owner and tier too" \
    test "$(q "select(.kind == \"Deployment\" or .kind == \"Job\") | .spec.template.metadata.labels | (.owner + \"/\" + .tier)")" = "$want_owner/$want_tier"
  # Our own images come from rarebit/<service> in the registry set at install time
  if [ -z "$(yq '.image.registry // ""' "$apps/$svc/values.yaml")" ]; then
    assert "$svc: image rarebit/${svc%-migrate} from the install-time registry" \
      bash -c "[[ \"\$(yq ea '$pod | .containers[0].image' '$f')\" == '$fake_registry/rarebit/${svc%-migrate}:'* ]]"
  fi
  if [ "$(q 'select(.kind == "Deployment") | .kind')" = Deployment ]; then
    assert "$svc: a readiness probe" test "$(q "$pod | .containers[0].readinessProbe != null")" = true
    assert "$svc: a liveness probe" test "$(q "$pod | .containers[0].livenessProbe != null")" = true
    # A liveness probe that gives up in under 10 s restarts pods on one slow GC pause or node hiccup.
    assert "$svc: liveness tolerates 10 s of failures" \
      test "$(q "$pod | .containers[0].livenessProbe | (.failureThreshold * .periodSeconds) >= 10")" = true
  fi
done

# The one load balancer: every Ingress joins IngressGroup rarebit with the same scheme and listener
# (CLAUDE.md rule 6), and only the game and the web UI have one.
ingresses="$(for svc in "${rendered[@]}"; do yq ea -o=json -I0 'select(.kind == "Ingress") | {"svc": "'"$svc"'", "a": .metadata.annotations, "paths": [.spec.rules[].http.paths[] | .path], "ports": [.spec.rules[].http.paths[].backend.service.port.name]}' "$tmp/$svc.yaml"; done |
  jq -s -c 'map(select(has("svc")))')" # yq prints an empty object for a file with no Ingress
assert "only game and web have an Ingress" test "$(jq -c '[.[].svc] | sort' <<<"$ingresses")" = '["game","web"]'
assert "every Ingress joins IngressGroup rarebit" test "$(jq '[.[].a["alb.ingress.kubernetes.io/group.name"] == "rarebit"] | all' <<<"$ingresses")" = true
assert "every Ingress has the same scheme and listener" \
  test "$(jq '[.[].a | [.["alb.ingress.kubernetes.io/scheme"], .["alb.ingress.kubernetes.io/listen-ports"]]] | unique | length' <<<"$ingresses")" = 1
assert "every Ingress targets pod IPs and checks /readyz" \
  test "$(jq '[.[].a | .["alb.ingress.kubernetes.io/target-type"] == "ip" and .["alb.ingress.kubernetes.io/healthcheck-path"] == "/readyz"] | all' <<<"$ingresses")" = true
assert "the game takes /socket.io, before the web UI's /" \
  test "$(jq -c 'map({(.svc): {paths, order: (.a["alb.ingress.kubernetes.io/group.order"] | tonumber)}}) | add | [.game.paths, .web.paths, .game.order < .web.order]' <<<"$ingresses")" = '[["/socket.io"],["/"],true]'
assert "no Ingress routes to a metrics port" test "$(jq '[.[].ports[]] | index("metrics") == null' <<<"$ingresses")" = true

# --- Part 3: shutdown timing (each service's README) -------------------------------------------------
# seconds <duration>: a Go or plain number of seconds ("5s", "20s", "15") as an integer
seconds() { [[ $1 =~ ^([0-9]+)s?$ ]] && echo "${BASH_REMATCH[1]}"; }
# timing <service> <field>: from the rendered Deployment's pod spec
timing() { yq ea "$pod | $2" "$tmp/$1.yaml"; }
env_of() { local v; v="$(timing "$1" ".containers[0].env[] | select(.name == \"$2\") | .value")"; seconds "${v:-$3}"; }
has() { [[ " ${rendered[*]} " == *" $1 "* ]]; }

if has game; then
  grace="$(timing game '.terminationGracePeriodSeconds')"
  pre="$(timing game '.containers[0].lifecycle.preStop.sleep.seconds // 0')"
  drain="$(env_of game DRAIN_DELAY_SECONDS 15)"
  shutdown="$(env_of game SHUTDOWN_TIMEOUT_SECONDS 10)"
  assert "game: readiness on /readyz, liveness on /healthz" \
    test "$(timing game '.containers[0] | .readinessProbe.httpGet.path + " " + .livenessProbe.httpGet.path')" = "/readyz /healthz"
  assert "game: readiness timeout of 2 s or more (/readyz waits up to 1 s for Redis)" \
    test "$(timing game '.containers[0].readinessProbe.timeoutSeconds >= 2')" = true
  assert "game: the grace period ($grace s) outlasts preStop + DRAIN_DELAY_SECONDS + 1 + SHUTDOWN_TIMEOUT_SECONDS ($pre + $drain + 1 + $shutdown s)" \
    test "$grace" -gt $((pre + drain + 1 + shutdown))
else
  bad "game didn't render, so its timing wasn't checked"
fi

if has validator; then
  grace="$(timing validator '.terminationGracePeriodSeconds')"
  pre="$(timing validator '.containers[0].lifecycle.preStop.sleep.seconds // 0')"
  drain="$(env_of validator VALIDATOR_DRAIN_DELAY 5s)"
  shutdown="$(env_of validator VALIDATOR_SHUTDOWN_TIMEOUT 20s)"
  assert "validator: readiness on /readyz, liveness on /healthz" \
    test "$(timing validator '.containers[0] | .readinessProbe.httpGet.path + " " + .livenessProbe.httpGet.path')" = "/readyz /healthz"
  assert "validator: readiness timeout of 2 s or more, and 3 failures or more (the check takes up to 1 s)" \
    test "$(timing validator '.containers[0].readinessProbe | (.timeoutSeconds >= 2 and .failureThreshold >= 3)')" = true
  assert "validator: a preStop pause or VALIDATOR_DRAIN_DELAY, not both" test "$pre" -eq 0 -o "$drain" -eq 0
  assert "validator: the grace period ($grace s) outlasts preStop + drain delay + shutdown timeout + 3 ($pre + $drain + $shutdown + 3 s)" \
    test "$grace" -gt $((pre + drain + shutdown + 3))
else
  bad "validator didn't render, so its timing wasn't checked"
fi

if has web; then
  grace="$(timing web '.terminationGracePeriodSeconds')"
  pre="$(timing web '.containers[0].lifecycle.preStop.sleep.seconds // 0')"
  dereg="$(yq ea 'select(.kind == "Ingress") | .metadata.annotations["alb.ingress.kubernetes.io/target-group-attributes"]' "$tmp/web.yaml" |
    grep -oE 'deregistration_delay\.timeout_seconds=[0-9]+' | cut -d= -f2)"
  assert "web: readiness on /readyz, liveness on /healthz" \
    test "$(timing web '.containers[0] | .readinessProbe.httpGet.path + " " + .livenessProbe.httpGet.path')" = "/readyz /healthz"
  assert "web: a preStop pause (${pre} s) at least as long as the ALB's deregistration delay (${dereg:-?} s): nginx refuses new connections at once on SIGQUIT" \
    test "$pre" -ge "${dereg:-999}"
  assert "web: the grace period ($grace s) outlasts the preStop pause + nginx's 10 s drain ($pre + 10 s)" \
    test "$grace" -gt $((pre + 10))
  assert "web: /tmp is an emptyDir" test "$(timing web '[.volumes[] | select(.name == "tmp") | .emptyDir != null] | any')" = true
else
  bad "web didn't render, so its timing wasn't checked"
fi

# --- Part 4: the schema refuses ----------------------------------------------------------------------
# refuse <name> <service> <helm args...>: the render must fail
refuse() {
  local name=$1 svc=$2
  shift 2
  if render "$svc" "$@" >/dev/null 2>&1; then bad "the schema accepts $name"; else pass=$((pass + 1)); fi
}
zeros="$(printf '0%.0s' $(seq 64))"
refuse "a tag without a digest" redis --set-string image.tag=8.10.3-alpine
refuse "latest" redis --set-string "image.tag=latest@sha256:$zeros"
refuse "a short digest" redis --set-string "image.tag=8.10.3@sha256:0000"
refuse "no owner" redis --set owner=
refuse "a tier the catalog doesn't have" redis --set-string tier=4
refuse "a misspelled key" redis --set replica=2
refuse "a deployment without probes" validator-migrate --set mode=deployment --set terminationGracePeriodSeconds=30
refuse "a deployment without a grace period" redis --set terminationGracePeriodSeconds=null
refuse "no resources" redis --set resources=null
refuse "no memory limit" redis --set resources.limits=null
refuse "a CPU limit (it only throttles)" redis --set resources.limits.cpu=1
refuse "an ingress class other than alb" redis --set ingress.className=nginx
refuse "a volume mount that doesn't say whether it's read-only" redis --set 'volumeMounts[0].name=data' --set 'volumeMounts[0].mountPath=/data' --set 'volumeMounts[0].readOnly=null'
refuse "a privileged port" redis --set port=80
refuse "root" redis --set securityContext.runAsUser=0

echo "deploy tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
