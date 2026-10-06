#!/usr/bin/env bash
# Dedicated acceptance namespace only; the remote acceptance tag is retained as evidence.
set -Eeuo pipefail
umask 077
[[ $# = 5 ]] || {
  echo 'registry-verify REGISTRY USER PASSWORD_FILE PINNED_BASE NAMESPACE' >&2
  exit 2
}
registry=$1 user=$2 password=$3 base=$4 namespace=$5
[[ $registry =~ ^[A-Za-z0-9_.:-]+$ && $user =~ ^[A-Za-z0-9_.@-]+$ ]] || exit 2
[[ $namespace =~ ^[a-z][a-z0-9_/-]+$ && $namespace != *..* ]] || exit 2
[[ $base =~ @sha256:[a-f0-9]{64}$ && -f $password ]] || exit 2
work=$(mktemp -d)
export DOCKER_CONFIG=$work/auth
mkdir -p -- "$DOCKER_CONFIG"
tag="$registry/$namespace:pg-ha-$(date -u +%Y%m%dT%H%M%S)-$$"
cleanup() {
  docker image rm -- "$tag" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker login "$registry" --username "$user" --password-stdin <"$password" >/dev/null
printf 'FROM %s\nLABEL ha.acceptance="%s"\n' "$base" "$(date -u +%FT%TZ)-$$" >"$work/Dockerfile"
docker build --pull=false --tag "$tag" "$work" >/dev/null
expected=$(docker image inspect --format '{{.Id}}' "$tag")
docker push "$tag" >"$work/push.txt"
docker image rm -- "$tag" >/dev/null
docker pull "$tag" >"$work/pull.txt"
actual=$(docker image inspect --format '{{.Id}}' "$tag")
[[ $actual = "$expected" ]] || {
  echo 'Docker image ID changed across push/pull' >&2
  exit 1
}
docker image inspect --format '{{json .RepoDigests}}' "$tag" >"$work/digests.json"
digest=$(jq -er --arg prefix "$registry/$namespace@sha256:" '.[]|select(startswith($prefix))' "$work/digests.json")
jq -n --arg tag "$tag" --arg digest "$digest" --arg id "$actual" --arg at "$(date -u +%FT%TZ)" \
  '{push:true,pull:true,image_id_equal:true,tag:$tag,repo_digest:$digest,completed_at:$at}'
