#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
project="$work/project"
mkdir -p "$project/scripts" "$project/tests" "$project/.local"
cp "$root/scripts/export-public.sh" "$project/scripts/"
cp "$root/tests/scan-secrets.sh" "$project/tests/"
cp "$root/LICENSE" "$root/SECURITY.md" "$root/THIRD_PARTY.md" "$project/"
printf '.local/\n.cache/\n' >"$project/.gitignore"
git -C "$project" init --quiet
git -C "$project" config user.name 'Private fixture author'
git -C "$project" config user.email private-fixture@example.invalid
git -C "$project" config commit.gpgSign false
printf 'historical private fixture\n' >"$project/.local/historical-input"
git -C "$project" add -f .local/historical-input
git -C "$project" commit --quiet -m 'Private historical fixture'
git -C "$project" rm --quiet .local/historical-input
git -C "$project" add .
git -C "$project" commit --quiet -m 'Current source only'
git -C "$project" remote add origin https://example.invalid/private-history.git
source_head=$(git -C "$project" rev-parse HEAD)
mkdir -p "$project/.local"
printf 'site.example.invalid\n' >"$project/.local/private-source-rules.txt"
HA_PRIVATE_SCAN_RULES=.local/private-source-rules.txt bash "$project/scripts/export-public.sh" >"$work/export.log"
destination=$(find "$project/.local/public" -mindepth 1 -maxdepth 1 -type d)
[[ $(git -C "$destination" rev-list --count --all) == 1 ]]
[[ -z $(git -C "$destination" remote) ]]
[[ -z $(git -C "$destination" log --all --format=%H -- .local/historical-input) ]]
[[ $(git -C "$destination" log -1 --format=%ae) == 'opensource@users.noreply.github.com' ]]
[[ $(git -C "$project" rev-parse HEAD) == "$source_head" ]]
[[ $(git -C "$project" rev-list --count --all) == 2 ]]
archive=$(find "$project/.local/dist" -name '*.tar.gz')
tar -tzf "$archive" >"$work/archive-files"
if grep -E '/[.]git/|/[.]local/' "$work/archive-files"; then
  echo 'Private metadata was included in the source bundle' >&2; exit 1
fi
tar -tzf "$archive" | grep -Fx 'one-postgres-ha/LICENSE' >/dev/null
printf 'uncommitted\n' >>"$project/LICENSE"
if bash "$project/scripts/export-public.sh" >"$work/rejected.log" 2>&1; then
  echo 'Uncommitted source was exported' >&2; exit 1
fi
git -C "$project" restore LICENSE
if HA_PUBLIC_AUTHOR_EMAIL=private-fixture@example.invalid bash "$project/scripts/export-public.sh" >"$work/rejected.log" 2>&1; then
  echo 'Private author email was accepted' >&2; exit 1
fi
for private_path in $'.local/private\tinput' .cache/private-input; do
  mkdir -p -- "$(dirname -- "$project/$private_path")"
  printf 'private fixture\n' >"$project/$private_path"
  git -C "$project" add -f -- "$private_path"
  git -C "$project" commit --quiet -m 'Tracked private path fixture'
  if bash "$project/scripts/export-public.sh" >"$work/rejected.log" 2>&1; then
    echo 'A tracked private path was copied into the public export' >&2; exit 1
  fi
  [[ $(find "$project/.local/public" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]]
  git -C "$project" rm --quiet -- "$private_path"
  git -C "$project" commit --quiet -m 'Remove tracked private path fixture'
done
echo 'PASS: public export isolates history, identity, remotes and runtime inputs'
