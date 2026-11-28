#!/usr/bin/env bash
# Builds the service images from a main commit, pushes them to the main ECR repositories as
# main-<sha7>, and writes each one's tag and digest into deploy/envs/<env>/<service>/image-tags.yaml.
#
#   bash deploy/push-images.sh <env> [<commit on origin/main>]   (default: origin/main)
#
# It pushes to AWS, so a person runs it (CLAUDE.md rule 2): people may push main images by hand as
# break-glass (ADR 0040), until CI builds and pushes them (#62). Main images come only from commits on
# origin/main, built in a clean checkout of that commit, so the tag always names what was built.
# Needs: docker, git, make, aws (logged in: aws login --profile rarebit), and RAREBIT_AWS_ACCOUNT_ID
# (.mise.local.toml).
set -euo pipefail

die() {
  printf 'push-images: %s\n' "$*" >&2
  exit 2
}

env="${1:-}"
ref="${2:-origin/main}"
[[ $env =~ ^[a-z0-9-]+$ ]] || die "usage: push-images.sh <env> [<commit on origin/main>]"
account="${RAREBIT_AWS_ACCOUNT_ID:-}"
[[ $account =~ ^[0-9]{12}$ ]] || die "RAREBIT_AWS_ACCOUNT_ID isn't set to the account ID (.mise.local.toml)"
region=eu-central-1
registry="$account.dkr.ecr.$region.amazonaws.com"
root="$(git rev-parse --show-toplevel)"
[ -d "$root/deploy/envs/$env" ] || die "no deploy/envs/$env"

git -C "$root" fetch -q origin main
commit="$(git -C "$root" rev-parse --verify "$ref^{commit}")" || die "no commit $ref"
git -C "$root" merge-base --is-ancestor "$commit" origin/main || die "$ref isn't on origin/main: main images come only from main commits"
sha="${commit:0:7}"

# A clean checkout of exactly that commit, outside the repo, removed at the end
build="$(mktemp -d)"
trap 'git -C "$root" worktree remove --force "$build/src" >/dev/null 2>&1 || true; rm -rf "$build"' EXIT
git -C "$root" worktree add -q --detach "$build/src" "$commit"

# The ECR login, which can push to every repository for 12 hours, goes into a Docker config of its
# own in $build, removed with it at the end. Not the user's credential store: on Windows that's
# Docker Desktop's, the Windows Credential Manager, which refuses a password over 2,560 bytes, and an
# ECR token made from `aws login` credentials can be longer (2,749 bytes on 2026-11-27). Builds keep
# the user's own config, so their builders and cache.
login="$build/docker-login"
mkdir -m 700 "$login"
aws ecr get-login-password --region "$region" |
  DOCKER_CONFIG="$login" docker login --username AWS --password-stdin "$registry" >/dev/null

for svc in validator game web; do
  local_image="rarebit-$svc:main-$sha"
  remote="$registry/rarebit/$svc:main-$sha"
  # Tags are immutable: on a re-run (after a failure part way), an image already pushed for this
  # commit is kept, by its digest, rather than built and pushed again.
  digest="$(aws ecr describe-images --region "$region" --repository-name "rarebit/$svc" --image-ids "imageTag=main-$sha"     --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)"
  if [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "kept $remote@$digest (already pushed)"
  else
    var="$(tr '[:lower:]' '[:upper:]' <<<"$svc")_IMAGE"
    make -C "$build/src" "$svc-image" "$var=$local_image"
    docker tag "$local_image" "$remote"
    DOCKER_CONFIG="$login" docker push -q "$remote"
    digest="$(docker image inspect "$remote" --format '{{range .RepoDigests}}{{println .}}{{end}}' |
      grep -m1 "^$registry/rarebit/$svc@" | cut -d@ -f2)"
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "no digest for $remote"
    echo "pushed $remote@$digest"
  fi
  mkdir -p "$root/deploy/envs/$env/$svc"
  printf '# Written by deploy/push-images.sh: %s, built from %s.\nimage:\n  tag: main-%s@%s\n' \
    "$svc" "$commit" "$sha" "$digest" >"$root/deploy/envs/$env/$svc/image-tags.yaml"
  # The migrate Job always runs the validator's own image (deploy/test/render.sh checks it).
  if [ "$svc" = validator ]; then
    cp "$root/deploy/envs/$env/validator/image-tags.yaml" "$root/deploy/envs/$env/validator-migrate/image-tags.yaml"
  fi
done
