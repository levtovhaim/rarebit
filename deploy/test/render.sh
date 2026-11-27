#!/usr/bin/env bash
# Tests for deploy/charts/service, every service's values in deploy/apps, and every environment's in
# deploy/envs (make deploy; in CI, the deploy check). ADR 0045.
#   Part 1: helm lint; every service renders, alone and in each environment, and passes kubeconform;
#           each environment's image-tags.yaml holds an image tag and nothing else.
#   Part 2: what every rendered workload has (CLAUDE.md rule 7 and Conventions), and the one ALB.
#   Part 3: each service's shutdown timing, against its README.
#   Part 4: the values schema refuses what the golden path doesn't allow.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
chart="$root/deploy/charts/service"
apps="$root/deploy/apps"
envs="$root/deploy/envs"
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

# What a render needs and git doesn't hold: the registry's host (it holds the account ID, ADR 0035),
# and, for deploy/apps alone, an image tag (an environment's image-tags.yaml holds the real one).
fake_registry=000000000000.dkr.ecr.eu-central-1.amazonaws.com
zeros="$(printf '0%.0s' $(seq 64))"
fake_tag="main-0000000@sha256:$zeros"
# Our own images' tags (CLAUDE.md → Conventions): an environment pins main builds by digest.
main_tag='^main-[0-9a-f]{7}@sha256:[0-9a-f]{64}$'

ours() { [ -z "$(yq '.image.registry // ""' "$apps/$1/values.yaml")" ]; }

# render <service> <environment or "-"> [helm args...]: the manifests on stdout
render() {
  local svc=$1 env=$2 sets=() f
  local files=(-f "$apps/$svc/values.yaml")
  shift 2
  if [ "$env" = - ]; then
    ours "$svc" && sets+=(--set-string "image.tag=$fake_tag")
  else
    for f in values.yaml image-tags.yaml; do
      [ -f "$envs/$env/$svc/$f" ] && files+=(-f "$envs/$env/$svc/$f")
    done
  fi
  ours "$svc" && sets+=(--set "image.registry=$fake_registry")
  helm template "$svc" "$chart" "${files[@]}" "${sets[@]}" "$@"
}

# The catalog entry a service's labels come from: validator-migrate is the validator's.
catalog_of() { printf '%s/catalog/%s.yaml' "$root" "${1%-migrate}"; }

name_ok() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }

mapfile -t services < <(find "$apps" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[ "${#services[@]}" -gt 0 ] || { echo "render.sh: no services in deploy/apps" >&2; exit 2; }
for svc in "${services[@]}"; do
  name_ok "$svc" || { echo "render.sh: deploy/apps/$svc isn't a release name" >&2; exit 2; }
done
mapfile -t environments < <([ -d "$envs" ] && find "$envs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

# --- Part 1: lint, render, schemas, image tags --------------------------------------------------------
assert "helm lint --strict (with the game's values)" \
  helm lint --strict "$chart" -f "$apps/game/values.yaml" --set "image.registry=$fake_registry" --set-string "image.tag=$fake_tag"

# Every render: "-/<service>" for deploy/apps alone, "<env>/<service>" for an environment's stack.
renders=()
check_render() {
  local env=$1 svc=$2 id="$1/$2" out="$tmp/${1}_${2}.yaml"
  if render "$svc" "$env" >"$out" 2>"$out.err"; then
    pass=$((pass + 1))
    renders+=("$id")
    assert "$id passes kubeconform" kubeconform -strict -summary -cache "${KUBECONFORM_CACHE:-$tmp}" "$out"
  else
    bad "$id renders: $(grep -m1 -v '^$' "$out.err")"
  fi
}
for svc in "${services[@]}"; do check_render - "$svc"; done

for env in "${environments[@]}"; do
  name_ok "$env" || { bad "deploy/envs/$env isn't a valid environment name"; continue; }
  mapfile -t env_services < <(find "$envs/$env" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  for svc in "${env_services[@]}"; do
    if ! name_ok "$svc" || [ ! -d "$apps/$svc" ]; then
      bad "deploy/envs/$env/$svc isn't a service in deploy/apps"
      continue
    fi
    tags="$envs/$env/$svc/image-tags.yaml"
    if ours "$svc"; then
      # A promotion changes only this file (CLAUDE.md → Conventions), and it has no code owner: it may
      # hold an image tag and nothing else.
      assert "$env/$svc: image-tags.yaml exists" test -f "$tags"
      assert "$env/$svc: image-tags.yaml holds image.tag and nothing else" \
        bash -c "yq -o=json '.' '$tags' | jq -e 'keys == [\"image\"] and (.image | keys) == [\"tag\"]'"
      assert "$env/$svc: the tag is a main build, by digest" \
        bash -c "[[ \"\$(yq '.image.tag' '$tags')\" =~ $main_tag ]]"
    else
      assert "$env/$svc: an upstream image has no image-tags.yaml" test ! -e "$tags"
    fi
    check_render "$env" "$svc"
  done
  # The migrate Job runs the serving binary's migrations: the two always share one image.
  if [ -f "$envs/$env/validator/image-tags.yaml" ] || [ -f "$envs/$env/validator-migrate/image-tags.yaml" ]; then
    assert "$env: validator and validator-migrate run the same image" \
      test "$(yq '.image.tag' "$envs/$env/validator/image-tags.yaml" 2>/dev/null)" = "$(yq '.image.tag' "$envs/$env/validator-migrate/image-tags.yaml" 2>/dev/null)"
  fi
done

# --- Part 2: every workload, and the one load balancer ------------------------------------------------
pod='select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec'
for id in "${renders[@]}"; do
  env="${id%%/*}"
  svc="${id#*/}"
  f="$tmp/${env}_${svc}.yaml"
  q() { yq ea "$1" "$f"; }
  cat="$(catalog_of "$svc")"
  assert "$id: has a catalog entry" test -f "$cat"
  assert "$id: one workload" test "$(q '[select(.kind == "Deployment" or .kind == "Job")] | length')" = 1
  assert "$id: runs as non-root" test "$(q "$pod | .securityContext.runAsNonRoot")" = true
  assert "$id: seccomp RuntimeDefault" test "$(q "$pod | .securityContext.seccompProfile.type")" = RuntimeDefault
  assert "$id: no service account token" test "$(q "$pod | .automountServiceAccountToken")" = false
  assert "$id: read-only root filesystem" test "$(q "$pod | .containers[0].securityContext.readOnlyRootFilesystem")" = true
  assert "$id: no privilege escalation" test "$(q "$pod | .containers[0].securityContext.allowPrivilegeEscalation")" = false
  assert "$id: drops every capability" test "$(q "$pod | .containers[0].securityContext.capabilities.drop | join(\",\")")" = ALL
  assert "$id: nothing from the node, no projected token" \
    test "$(q "[$pod | .volumes[]? | select(has(\"hostPath\") or has(\"projected\"))] | length")" = 0
  assert "$id: requests CPU and memory, and limits memory" \
    test "$(q "$pod | .containers[0].resources | (.requests.cpu != null and .requests.memory != null and .limits.memory != null)")" = true
  assert "$id: the image is pinned by digest" bash -c "[[ \"\$(yq ea '$pod | .containers[0].image' '$f')\" == *@sha256:* ]]"
  # Labels: CLAUDE.md → Conventions, the owner and tier from the catalog
  want_owner="$(yq '.spec.owner | sub("^user:"; "")' "$cat" 2>/dev/null)"
  want_tier="$(yq '.metadata.labels.tier' "$cat" 2>/dev/null)"
  for kind in "$(q 'select(.kind == "Deployment" or .kind == "Job") | .kind')" Service ServiceAccount Ingress; do
    [ "$(q "[select(.kind == \"$kind\")] | length")" = 0 ] && continue
    labels="$(q "select(.kind == \"$kind\") | .metadata.labels")"
    assert "$id $kind: part-of rarebit" test "$(yq '.["app.kubernetes.io/part-of"]' <<<"$labels")" = rarebit
    assert "$id $kind: name label" test "$(yq '.["app.kubernetes.io/name"]' <<<"$labels")" = "$svc"
    assert "$id $kind: owner $want_owner (catalog)" test "$(yq '.owner' <<<"$labels")" = "$want_owner"
    assert "$id $kind: tier $want_tier (catalog)" test "$(yq '.tier' <<<"$labels")" = "$want_tier"
  done
  pod_labels='select(.kind == "Deployment" or .kind == "Job") | .spec.template.metadata.labels'
  assert "$id: pod labels carry owner and tier too" test "$(q "$pod_labels | (.owner + \"/\" + .tier)")" = "$want_owner/$want_tier"
  # A chart release alone must never restart a pod.
  assert "$id: no chart version in the pod's labels" test "$(q "$pod_labels | has(\"helm.sh/chart\")")" = false
  if ours "$svc"; then
    assert "$id: image rarebit/${svc%-migrate} from the install-time registry" \
      bash -c "[[ \"\$(yq ea '$pod | .containers[0].image' '$f')\" == '$fake_registry/rarebit/${svc%-migrate}:'* ]]"
  fi
  if [ "$(q 'select(.kind == "Deployment") | .kind')" = Deployment ]; then
    assert "$id: a readiness probe" test "$(q "$pod | .containers[0].readinessProbe != null")" = true
    assert "$id: a liveness probe" test "$(q "$pod | .containers[0].livenessProbe != null")" = true
    # A liveness probe that gives up in under 10 s restarts pods on one slow GC pause or node hiccup.
    assert "$id: liveness tolerates 10 s of failures" \
      test "$(q "$pod | .containers[0].livenessProbe | (.failureThreshold * .periodSeconds) >= 10")" = true
  fi
done

# The one load balancer, in deploy/apps and in each environment: every Ingress joins IngressGroup
# rarebit with the same group settings (CLAUDE.md rule 6), and only the game and the web UI have one.
for set in - "${environments[@]}"; do
  ingresses="$(for id in "${renders[@]}"; do
    [ "${id%%/*}" = "$set" ] || continue
    yq ea -o=json -I0 'select(.kind == "Ingress") | {"svc": "'"${id#*/}"'", "a": .metadata.annotations, "paths": [.spec.rules[].http.paths[] | .path], "ports": [.spec.rules[].http.paths[].backend.service.port.name]}' "$tmp/${set}_${id#*/}.yaml"
  done | jq -s -c 'map(select(has("svc")))')" # yq prints an empty object for a file with no Ingress
  label="${set/#-/deploy\/apps}"
  [ "$set" != - ] && [ "$ingresses" = "[]" ] && continue
  assert "$label: only game and web have an Ingress" test "$(jq -c '[.[].svc] | sort' <<<"$ingresses")" = '["game","web"]'
  assert "$label: every Ingress joins IngressGroup rarebit" test "$(jq '[.[].a["alb.ingress.kubernetes.io/group.name"] == "rarebit"] | all' <<<"$ingresses")" = true
  assert "$label: every Ingress has the same group settings" \
    test "$(jq '[.[].a | del(.["alb.ingress.kubernetes.io/group.order"], .["alb.ingress.kubernetes.io/target-group-attributes"])] | unique | length' <<<"$ingresses")" = 1
  assert "$label: every Ingress targets pod IPs and checks /readyz" \
    test "$(jq '[.[].a | .["alb.ingress.kubernetes.io/target-type"] == "ip" and .["alb.ingress.kubernetes.io/healthcheck-path"] == "/readyz"] | all' <<<"$ingresses")" = true
  assert "$label: the game takes /socket.io, before the web UI's /" \
    test "$(jq -c 'map({(.svc): {paths, order: (.a["alb.ingress.kubernetes.io/group.order"] | tonumber)}}) | add | [.game.paths, .web.paths, .game.order < .web.order]' <<<"$ingresses")" = '[["/socket.io"],["/"],true]'
  assert "$label: no Ingress routes to a metrics port" test "$(jq '[.[].ports[]] | index("metrics") == null' <<<"$ingresses")" = true
done

# --- Part 3: shutdown timing (each service's README), on deploy/apps ----------------------------------
# seconds <duration>: a Go or plain number of seconds ("5s", "20s", "15") as an integer
seconds() { [[ $1 =~ ^([0-9]+)s?$ ]] && echo "${BASH_REMATCH[1]}"; }
# timing <service> <field>: from the rendered Deployment's pod spec
timing() { yq ea "$pod | $2" "$tmp/-_$1.yaml"; }
env_of() { local v; v="$(timing "$1" ".containers[0].env[] | select(.name == \"$2\") | .value")"; seconds "${v:-$3}"; }
dereg_of() {
  yq ea 'select(.kind == "Ingress") | .metadata.annotations["alb.ingress.kubernetes.io/target-group-attributes"]' "$tmp/-_$1.yaml" |
    grep -oE 'deregistration_delay\.timeout_seconds=[0-9]+' | cut -d= -f2
}
has() { [[ " ${renders[*]} " == *" -/$1 "* ]]; }

if has game; then
  grace="$(timing game '.terminationGracePeriodSeconds')"
  pre="$(timing game '.containers[0].lifecycle.preStop.sleep.seconds // 0')"
  drain="$(env_of game DRAIN_DELAY_SECONDS 15)"
  shutdown="$(env_of game SHUTDOWN_TIMEOUT_SECONDS 10)"
  dereg="$(dereg_of game)"
  assert "game: readiness on /readyz, liveness on /healthz" \
    test "$(timing game '.containers[0] | .readinessProbe.httpGet.path + " " + .livenessProbe.httpGet.path')" = "/readyz /healthz"
  assert "game: readiness timeout of 2 s or more (/readyz waits up to 1 s for Redis)" \
    test "$(timing game '.containers[0].readinessProbe.timeoutSeconds >= 2')" = true
  assert "game: the grace period ($grace s) outlasts preStop + DRAIN_DELAY_SECONDS + 1 + SHUTDOWN_TIMEOUT_SECONDS ($pre + $drain + 1 + $shutdown s)" \
    test "$grace" -gt $((pre + drain + 1 + shutdown))
  assert "game: the ALB keeps a draining pod's sockets (deregistration ${dereg:-?} s) until it has told its players to reconnect and shut down ($drain + 1 + $shutdown s)" \
    test "${dereg:-0}" -ge $((drain + 1 + shutdown))
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
  dereg="$(dereg_of web)"
  assert "web: readiness on /readyz, liveness on /healthz" \
    test "$(timing web '.containers[0] | .readinessProbe.httpGet.path + " " + .livenessProbe.httpGet.path')" = "/readyz /healthz"
  # nginx refuses new connections the moment SIGQUIT arrives: the pause covers the time the Service
  # and the ALB take to stop sending new requests, and the deregistration delay ends within the
  # nginx drain after it.
  assert "web: a preStop pause of 15 s or more ($pre s), while the Service and the ALB drop the pod" test "$pre" -ge 15
  assert "web: the deregistration delay (${dereg:-?} s) ends by the pause + nginx's 10 s drain ($pre + 10 s)" \
    test "${dereg:-999}" -le $((pre + 10))
  assert "web: the grace period ($grace s) outlasts the preStop pause + nginx's 10 s drain ($pre + 10 s)" \
    test "$grace" -gt $((pre + 10))
  assert "web: /tmp is an emptyDir" test "$(timing web '[.volumes[] | select(.name == "tmp") | .emptyDir != null] | any')" = true
else
  bad "web didn't render, so its timing wasn't checked"
fi

if has redis; then
  assert "redis: rolls with Recreate, never two side by side" \
    test "$(yq ea 'select(.kind == "Deployment") | .spec.strategy.type' "$tmp/-_redis.yaml")" = Recreate
  assert "redis: its memory request equals its limit" \
    test "$(timing redis '.containers[0].resources | .requests.memory == .limits.memory')" = true
  assert "redis: requires a password" bash -c "yq ea '$pod | .containers[0].args | join(\" \")' '$tmp/-_redis.yaml' | grep -q -- '--requirepass \$(REDIS_PASSWORD)'"
else
  bad "redis didn't render, so it wasn't checked"
fi

# --- Part 4: the schema refuses ------------------------------------------------------------------------
# refuse <name> <service> <helm args...>: the render must fail
refuse() {
  local name=$1 svc=$2
  shift 2
  if render "$svc" - "$@" >/dev/null 2>&1; then bad "the schema accepts $name"; else pass=$((pass + 1)); fi
}
refuse "a tag without a digest" redis --set-string image.tag=8.10.3-alpine
refuse "latest" redis --set-string "image.tag=latest@sha256:$zeros"
refuse "a short digest" redis --set-string "image.tag=8.10.3@sha256:0000"
refuse "another registry" redis --set image.registry=ghcr.io
refuse "another repository" game --set image.repository=someone/game
refuse "no owner" redis --set owner=
refuse "a tier the catalog doesn't have" redis --set-string tier=4
refuse "a misspelled key" redis --set replica=2
refuse "a deployment without probes" validator-migrate --set mode=deployment --set terminationGracePeriodSeconds=30
refuse "a deployment without a grace period" redis --set terminationGracePeriodSeconds=null
refuse "no resources" redis --set resources=null
refuse "no memory limit" redis --set resources.limits=null
refuse "a CPU limit (it only throttles)" redis --set resources.limits.cpu=1
refuse "an ingress class other than alb" redis --set ingress.className=nginx
refuse "another IngressGroup" game --set 'ingress.annotations.alb\.ingress\.kubernetes\.io/group\.name=other'
refuse "an annotation the chart doesn't allow" game --set 'ingress.annotations.alb\.ingress\.kubernetes\.io/actions\.redirect=x'
refuse "a volume from the node (hostPath)" redis --set 'volumes[0].name=host' --set 'volumes[0].hostPath.path=/'
refuse "a projected service account token" redis --set 'volumes[0].name=token' --set 'volumes[0].projected.sources[0].serviceAccountToken.path=token'
refuse "an emptyDir without a size limit" redis --set 'volumes[0].emptyDir.sizeLimit=null'
refuse "a volume mount with an extra key" redis --set 'volumeMounts[0].name=data' --set 'volumeMounts[0].mountPath=/data' --set 'volumeMounts[0].readOnly=false' --set 'volumeMounts[0].mountPropagation=Bidirectional'
refuse "a volume mount that doesn't say whether it's read-only" redis --set 'volumeMounts[0].name=data' --set 'volumeMounts[0].mountPath=/data' --set 'volumeMounts[0].readOnly=null'
refuse "DATABASE_URL as a value" validator --set 'extraEnv[0].name=DATABASE_URL' --set 'extraEnv[0].value=postgres://app:pw@db/app'
refuse "a password as a value" game --set 'extraEnv[0].name=REDIS_PASSWORD' --set 'extraEnv[0].value=hunter2'
refuse "a password inside a URL" game --set 'extraEnv[0].name=CACHE_URL' --set 'extraEnv[0].value=redis://:hunter2@cache:6379'
refuse "a variable with both a value and a reference" game --set 'extraEnv[0].name=X' --set 'extraEnv[0].value=1' --set 'extraEnv[0].valueFrom.secretKeyRef.name=s' --set 'extraEnv[0].valueFrom.secretKeyRef.key=k'
refuse "a privileged port" redis --set port=80
refuse "root" redis --set securityContext.runAsUser=0

echo "deploy tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
