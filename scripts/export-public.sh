#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $# -eq 0 ]] || { echo 'export-public.sh accepts no arguments' >&2; exit 2; }
repo_git() { git -c safe.directory="$ROOT" -C "$ROOT" "$@"; }
repo_git diff --quiet HEAD || { echo 'Commit tracked source changes before public export' >&2; exit 1; }
[[ -z $(repo_git ls-files --others --exclude-standard) ]] || { echo 'Commit new source files before public export' >&2; exit 1; }
repo_git ls-files --error-unmatch LICENSE SECURITY.md THIRD_PARTY.md >/dev/null
if [[ ${HA_PRIVATE_SCAN_RULES+x} ]]; then
  case "$HA_PRIVATE_SCAN_RULES" in /*) ;; *) HA_PRIVATE_SCAN_RULES="$ROOT/$HA_PRIVATE_SCAN_RULES" ;; esac
  export HA_PRIVATE_SCAN_RULES
fi
bash "$ROOT/tests/scan-secrets.sh"
author_name=${HA_PUBLIC_AUTHOR_NAME:-one-postgres-ha contributors}
author_email=${HA_PUBLIC_AUTHOR_EMAIL:-opensource@users.noreply.github.com}
[[ -n "$author_name" && "$author_name" != *$'\n'* && "$author_name" != *$'\r'* ]] || { echo 'Invalid public author name' >&2; exit 1; }
[[ "$author_email" =~ ^[A-Za-z0-9_.+-]+@users[.]noreply[.]github[.]com$ ]] || { echo 'Use an explicit GitHub noreply email for public export' >&2; exit 1; }
rev=$(repo_git rev-parse --short=12 HEAD)
mkdir -p "$ROOT/.local/public" "$ROOT/.local/dist"
destination=$(mktemp -d "$ROOT/.local/public/one-postgres-ha-$rev.XXXXXXXX")
# Copy a source snapshot, never clone the private repository or reuse its objects.
repo_git archive HEAD | tar -x -C "$destination"
[[ -z $(find "$destination" \( -name .local -o -name .cache -o -name .ansible -o -name .git \) -print -quit) ]] ||
  { echo 'Private runtime directories cannot be exported' >&2; exit 1; }
[[ -z $(find "$destination" -type l -print -quit) ]] || { echo 'Review source symlinks before public export' >&2; exit 1; }
(
  cd "$destination"
  git -c init.defaultBranch=main init --quiet
  git -c safe.directory="$destination" add .
  # Recheck tracked inputs now that this directory is an independent repository.
  bash tests/scan-secrets.sh
  GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
    GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
    git -c safe.directory="$destination" -c core.hooksPath=/dev/null -c commit.gpgSign=false \
      commit --quiet -m 'Initial open-source source snapshot'
)
[[ $(git -c safe.directory="$destination" -C "$destination" rev-list --count --all) == 1 ]]
[[ -z $(git -c safe.directory="$destination" -C "$destination" remote) ]]
archive="$ROOT/.local/dist/one-postgres-ha-public-$rev.tar.gz"
git -c safe.directory="$destination" -C "$destination" archive --format=tar.gz --prefix=one-postgres-ha/ HEAD >"$archive"
(cd "$ROOT/.local/dist" && sha256sum "$(basename -- "$archive")") >"$archive.sha256"
printf 'Public source repository (one commit, no remote): %s\nSource bundle: %s\n' "$destination" "$archive"
