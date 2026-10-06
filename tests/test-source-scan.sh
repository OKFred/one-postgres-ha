#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/project/tests" "$work/project/.local"
cp "$root/tests/scan-secrets.sh" "$work/project/tests/"
git -C "$work/project" init --quiet
printf 'example source\n' >"$work/project/README.md"
printf 'site.example.invalid\n' >"$work/project/.local/private-source-rules.txt"
bash "$work/project/tests/scan-secrets.sh" >/dev/null
if HA_PRIVATE_SCAN_RULES="$work/missing-rules" bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'Missing explicit private rules were accepted' >&2; exit 1
fi
printf 'site[.]example[.]invalid\n' >"$work/project/exposed.txt"
if bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'Reversible site identifiers were accepted' >&2; exit 1
fi
if grep -F 'site.example.invalid' "$work/result"; then
  echo 'A private source rule leaked into the report' >&2; exit 1
fi
rm -- "$work/project/exposed.txt"
printf '%s%s\n' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789ab' >"$work/project/exposed.txt"
if bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'A source credential pattern was accepted' >&2; exit 1
fi
if grep -F 'abcdefghijklmnopqrstuvwxyz0123456789ab' "$work/result"; then
  echo 'A credential value leaked into the report' >&2; exit 1
fi
rm -- "$work/project/exposed.txt"
mv -- "$work/project/.local/private-source-rules.txt" "$work/private-rules"
ln -s "$work/missing-rules" "$work/project/.local/private-source-rules.txt"
if bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'Dangling private rules symlink was accepted' >&2; exit 1
fi
rm -- "$work/project/.local/private-source-rules.txt"
mv -- "$work/private-rules" "$work/project/.local/private-source-rules.txt"
printf 'private fixture\n' >"$work/project/.local/private-input"
git -C "$work/project" add -f .local/private-input
if bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'Tracked private inputs were accepted' >&2; exit 1
fi
git -C "$work/project" rm --cached --quiet .local/private-input
quoted_path=$'.local/private\tinput'
printf 'private fixture\n' >"$work/project/$quoted_path"
git -C "$work/project" add -f -- "$quoted_path"
if bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'Quoted tracked private paths were accepted' >&2; exit 1
fi
git -C "$work/project" rm --cached --quiet -- "$quoted_path"
mkdir -p "$work/project/.cache"
printf 'private fixture\n' >"$work/project/.cache/private-input"
git -C "$work/project" add -f .cache/private-input
if bash "$work/project/tests/scan-secrets.sh" >"$work/result" 2>&1; then
  echo 'Tracked private cache files were accepted' >&2; exit 1
fi
echo 'PASS: source credential, reversible identifier and tracked-private checks'
