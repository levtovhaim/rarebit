#!/usr/bin/env bash
# Brings prod's EKS environment up, or tears it down, in the order docs/runbooks/eks.md explains.
#
#   bash platform/env.sh up     [--yes]   network, cluster, add-ons, Postgres, the services (about 25 min)
#   bash platform/env.sh down   [--yes]   the services and their ALB, Postgres, the controllers, the cluster,
#                                         the network, then the leak check (about 15 min)
#   bash platform/env.sh status           what exists now and the game's link (read-only)
#
# up and down change AWS, so a person runs them (CLAUDE.md rule 2): in WSL, from the repo root (mise's
# tools and .mise.local.toml), right after `aws login --profile rarebit`, so the login lasts the run.
# Without --yes, Terraform shows each plan and asks, and down asks once before it starts. --yes asks
# nothing, for unattended runs. Every step can run again: when a run stops part way, fix the cause and
# run the same command again. `plat env up` and `plat env down` will call this script (ADR 0049).
set -euo pipefail
shopt -s inherit_errexit

region=eu-central-1
cluster=rarebit-prod
ctx=rarebit-prod
ns=rarebit
export AWS_PROFILE=rarebit AWS_REGION="$region" AWS_PAGER=""

die() {
  printf 'env: %s\n' "$*" >&2
  exit 2
}
usage() { die "usage: bash platform/env.sh up|down|status [--yes]"; }

current="start"
step() {
  current="$*"
  printf '\n== %s  [%dm%02ds]\n' "$*" $((SECONDS / 60)) $((SECONDS % 60))
}

kc() { kubectl --context "$ctx" "$@"; }
hm() { helm --kube-context "$ctx" "$@"; }

tg() { # tg <unit> <apply|destroy>: one Terragrunt unit under infra/live/prod
  local flags=()
  [ "$yes" = 0 ] || flags=(-auto-approve)
  (cd "infra/live/prod/$1" && terragrunt "$2" "${flags[@]}")
}

# The cluster's status (ACTIVE, CREATING, DELETING...), or NONE when there's no cluster. Any other
# error stops the script: "couldn't read it" must not be taken for "it's gone".
cluster_status() {
  local out
  if out="$(aws eks describe-cluster --name "$cluster" --query cluster.status --output text 2>&1)"; then
    echo "$out"
  elif [[ $out == *ResourceNotFoundException* ]]; then
    echo NONE
  else
    die "couldn't read the cluster: $out"
  fi
}

use_cluster() {
  aws eks update-kubeconfig --name "$cluster" --alias "$ctx" >/dev/null
  kc get namespace kube-system >/dev/null ||
    die "the cluster doesn't answer: is RAREBIT_ADMIN_CIDR still your address? (runbook: kubectl times out)"
}

# What the LB controller made outside Terraform that still exists: the ALB, its target groups and its
# security groups. Prints nothing when they're all gone. Each call checks its own exit status: errexit
# doesn't apply inside a function called on the left of ||.
controller_leftovers() {
  aws elbv2 describe-load-balancers --output text \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-rarebit')].LoadBalancerName" || return 1
  aws elbv2 describe-target-groups --output text \
    --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupName" || return 1
  aws ec2 describe-security-groups --output text --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$cluster" \
    --query 'SecurityGroups[].GroupId' || return 1
}

wait_gone() { # wait_gone <what> <seconds> <command...>: until the command prints nothing
  local what="$1" limit="$2" left
  local end=$((SECONDS + limit))
  shift 2
  while :; do
    left="$("$@")" || die "couldn't check $what"
    left="$(tr -s '[:space:]' ' ' <<<"$left" | sed 's/^ //; s/ $//')"
    [ -n "$left" ] || return 0
    [ "$SECONDS" -lt "$end" ] || die "$what still there after ${limit}s: $left"
    printf '  waiting for %s: %s\n' "$what" "$left"
    sleep 10
  done
}

# Everything that bills by the hour, or blocks the next up. Returns 1 when something is left.
leftovers() {
  local found=0 what out
  check() { # check <what> <aws arguments...>
    what="$1"
    shift
    out="$(aws "$@" --output text)" || die "couldn't check $what"
    out="$(tr -s '[:space:]' ' ' <<<"$out" | sed 's/^ //; s/ $//')"
    if [ -n "$out" ] && [ "$out" != None ]; then
      printf '  found: %s: %s\n' "$what" "$out"
      found=1
    else
      printf '  none: %s\n' "$what"
    fi
  }
  check "EKS clusters" eks list-clusters --query clusters
  check "load balancers" elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
  check "instances" ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped
  check "unattached volumes" ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
  check "public addresses" ec2 describe-addresses --query 'Addresses[].AllocationId'
  check "the VPC" ec2 describe-vpcs --filters Name=tag:Project,Values=rarebit --query 'Vpcs[].VpcId'
  return "$found"
}

preflight() {
  local tool account mine
  for tool in aws terragrunt terraform kubectl helm curl openssl; do
    command -v "$tool" >/dev/null || die "$tool isn't on PATH: run this in WSL from the repo root, after mise install"
  done
  [[ ${RAREBIT_AWS_ACCOUNT_ID:-} =~ ^[0-9]{12}$ ]] || die "RAREBIT_AWS_ACCOUNT_ID isn't set (.mise.local.toml)"
  account="$(aws sts get-caller-identity --query Account --output text)" ||
    die "AWS doesn't know you: aws login --profile rarebit"
  [ "$account" = "$RAREBIT_AWS_ACCOUNT_ID" ] || die "logged in to another AWS account: this runs only in the project account"
  mine="$(curl -fsS --max-time 5 https://checkip.amazonaws.com)/32" || die "couldn't read your public address"
  [ "${RAREBIT_ADMIN_CIDR:-}" = "$mine" ] ||
    die "RAREBIT_ADMIN_CIDR is ${RAREBIT_ADMIN_CIDR:-not set}, but your address is now $mine: set it in .mise.local.toml, then run again"
}

deploy() { # deploy <service>: deploy/apps, then deploy/envs/prod where it has values for it
  local files=(-f "deploy/apps/$1/values.yaml") sets=() f
  for f in values.yaml image-tags.yaml; do
    [ ! -f "deploy/envs/prod/$1/$f" ] || files+=(-f "deploy/envs/prod/$1/$f")
  done
  [ "$1" = redis ] || sets+=(--set image.registry="$RAREBIT_AWS_ACCOUNT_ID.dkr.ecr.$region.amazonaws.com")
  hm upgrade --install "$1" deploy/charts/service -n "$ns" "${files[@]}" "${sets[@]}" \
    --wait --wait-for-jobs --timeout 15m
}

up() {
  # Before anything bills: every image prod pins must be in ECR, or the rollouts wait 15 minutes for nothing.
  step "Images"
  local svc tag repo
  for svc in validator-migrate validator game web; do
    tag="$(sed -n 's/^ *tag: *//p' "deploy/envs/prod/$svc/image-tags.yaml")"
    [[ $tag =~ ^main-[0-9a-f]{7}@(sha256:[0-9a-f]{64})$ ]] ||
      die "deploy/envs/prod/$svc/image-tags.yaml pins no main-<sha7>@sha256 image"
    repo="rarebit/${svc%-migrate}"
    aws ecr describe-images --repository-name "$repo" --image-ids "imageDigest=${BASH_REMATCH[1]}" >/dev/null ||
      die "$repo@${BASH_REMATCH[1]} isn't in ECR: run bash deploy/push-images.sh prod"
    echo "  $repo:$tag"
  done

  step "Network (about 3 min)"
  tg network apply
  step "Cluster (about 15 min)"
  tg eks apply
  step "kubectl"
  use_cluster
  kc wait node --all --for=condition=Ready --timeout=10m
  step "Namespace"
  kc apply -f deploy/platform/namespace.yaml

  step "AWS Load Balancer Controller"
  helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
  local vpc
  vpc="$(cd infra/live/prod/network && terragrunt output -raw vpc_id)"
  [[ $vpc =~ ^vpc-[0-9a-f]+$ ]] || die "the network unit has no vpc_id output"
  hm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.3 \
    -n kube-system -f deploy/platform/aws-load-balancer-controller/values.yaml --set vpcId="$vpc" --wait

  step "Postgres"
  hm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.2 -n cnpg-system --create-namespace \
    -f deploy/platform/cloudnative-pg/values.yaml --wait
  kc apply -f deploy/platform/postgres/cluster.yaml
  kc -n "$ns" wait cluster/rarebit-pg --for=condition=Ready --timeout=10m

  # Created once: a run again keeps Redis's password, and the game's real origin comes after the ALB.
  step "Redis's password, the game's origin"
  kc -n "$ns" get secret redis >/dev/null 2>&1 ||
    kc -n "$ns" create secret generic redis --from-literal=password="$(openssl rand -hex 24)"
  kc -n "$ns" get configmap game-origin >/dev/null 2>&1 ||
    kc -n "$ns" create configmap game-origin --from-literal=origins=http://placeholder.invalid

  for svc in redis validator-migrate validator game web; do
    step "Service: $svc"
    deploy "$svc"
  done

  # The game refuses WebSockets from any other origin, and only reads it at start: set it, then restart.
  step "The game's origin"
  local alb="" _
  for _ in $(seq 60); do
    alb="$(kc -n "$ns" get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    [ -z "$alb" ] || break
    sleep 5
  done
  [ -n "$alb" ] || die "the ALB has no address after 5 min (runbook: No ALB appears)"
  local origin="http://$alb"
  if [ "$(kc -n "$ns" get configmap game-origin -o jsonpath='{.data.origins}')" != "$origin" ]; then
    kc -n "$ns" patch configmap game-origin --type merge -p "{\"data\":{\"origins\":\"$origin\"}}"
    kc -n "$ns" rollout restart deploy/game
  fi
  kc -n "$ns" rollout status deploy/game --timeout=10m

  # A new ALB's name takes a minute or two to resolve.
  step "Check"
  curl -fsS --retry 30 --retry-delay 10 --retry-all-errors --max-time 10 "$origin/" | grep -q 'id="root"' ||
    die "the page at $origin doesn't answer"
  printf '\nRarebit is up: %s\nIt costs about %s/h until: bash platform/env.sh down\n' "$origin" "\$0.36"
}

down() {
  if [ "$yes" = 0 ]; then
    local answer
    read -r -p "Tear prod down? The game goes offline and its data is deleted. Type down to continue: " answer
    [ "$answer" = down ] || die "stopped; nothing changed"
  fi

  # The controllers delete what they made (the ALB, Postgres's volume), so they go after it and before
  # the cluster. Without a cluster, there's nothing of theirs left to delete this way.
  local state
  state="$(cluster_status)"
  if [ "$state" != NONE ]; then
    step "kubectl"
    use_cluster
    step "Services, and the ALB with their Ingresses"
    hm -n "$ns" uninstall web game validator validator-migrate redis --ignore-not-found --wait
    wait_gone "the ALB, its target groups and security groups" 600 controller_leftovers
    step "Postgres and its volume"
    if kc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
      kc delete -f deploy/platform/postgres/cluster.yaml --ignore-not-found --wait --timeout=5m
    fi
    wait_gone "Postgres's volume" 600 kc get pv -o name
    step "Controllers"
    hm -n cnpg-system uninstall cnpg --ignore-not-found --wait
    hm -n kube-system uninstall aws-load-balancer-controller --ignore-not-found --wait
  fi

  # An ALB left in the VPC makes the network's destroy hang, and nothing would delete it any more.
  step "Nothing the controllers made is left"
  local left
  left="$(controller_leftovers | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  [ -z "$left" ] || die "still there: $left. Delete them by hand (runbook: Tear down, leak check), then run again"

  step "Cluster (about 10 min)"
  tg eks destroy
  step "Network (about 3 min)"
  tg network destroy
  step "Leak check"
  leftovers || die "something is left, and it may bill (runbook: Tear down, leak check)"
  printf '\nprod is down. Nothing that bills by the hour is left.\n'
}

status() {
  local state
  state="$(cluster_status)"
  echo "cluster $cluster: $state"
  if [ "$state" = ACTIVE ]; then
    use_cluster
    kc get nodes --no-headers
    local alb
    alb="$(kc -n "$ns" get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [ -n "$alb" ]; then echo "link: http://$alb"; else echo "link: none (no Ingress yet)"; fi
  fi
  echo "what exists:"
  leftovers || echo "(it bills while it's up: about \$0.36/h with the cluster, docs/cost.md)"
}

cmd="${1:-}"
[ $# -eq 0 ] || shift
yes=0
for arg in "$@"; do
  case "$arg" in
    --yes | -y) yes=1 ;;
    *) usage ;;
  esac
done
case "$cmd" in
  up | down | status) ;;
  *) usage ;;
esac
[ "$yes" = 0 ] || export TG_NON_INTERACTIVE=true
cd "$(dirname "$0")/.."

on_exit() {
  local rc=$?
  [ "$rc" = 0 ] || [ "$current" = start ] || printf '\nenv: %s stopped at: %s [%dm%02ds]. Fix the cause, then run the same command again.\n' \
    "$cmd" "$current" $((SECONDS / 60)) $((SECONDS % 60)) >&2
}
trap on_exit EXIT

preflight
"$cmd"
