#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Include untracked source, but never private runtime inputs.
find . -path './.git' -prune -o -path './.local' -prune -o -path './.cache' -prune -o -type f -print0 >"$work/files"
pattern='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|(^|[^A-Za-z0-9])(AKIA|ASIA)[A-Z0-9]{16}|LTAI[A-Za-z0-9]{16,32}|gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{60,255}'
while IFS= read -r -d '' file; do
  if grep -IlE -- "$pattern" "$file"; then
    echo 'A credential pattern was found in deliverable files; values withheld' >&2
    exit 1
  else
    result=$?
    [[ $result == 1 ]] || { echo 'Source credential scan failed' >&2; exit 1; }
  fi
done <"$work/files"
if git -c safe.directory="$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -c safe.directory="$PWD" ls-files -z >"$work/tracked"
  while IFS= read -r -d '' file; do
    case "$file" in
      .local | .local/* | */.local | */.local/* | .cache | .cache/* | */.cache | */.cache/* | \
        .ansible | .ansible/* | */.ansible | */.ansible/* | .env | */.env | *.key | *.pem | *.dump | *.sql.gz)
        echo 'Private runtime files are tracked (paths withheld)' >&2
        exit 1
        ;;
    esac
  done <"$work/tracked"
fi
# Site identifiers belong in ignored private input, never in public rules.
rules=${HA_PRIVATE_SCAN_RULES-.local/private-source-rules.txt}
if [[ ${HA_PRIVATE_SCAN_RULES+x} && (! -f "$rules" || -L "$rules") ]]; then
  echo 'Explicit private source rules file is missing or invalid' >&2
  exit 1
fi
if [[ -e "$rules" || -L "$rules" ]]; then
  [[ -f "$rules" && ! -L "$rules" ]] || { echo 'Invalid private source rules file' >&2; exit 1; }
  if grep -vE '^[[:space:]]*(#.*)?$' "$rules" >"$work/rules"; then :; else
    result=$?
    [[ $result == 1 ]] || { echo 'Could not read private source rules' >&2; exit 1; }
  fi
  if [[ -s "$work/rules" ]]; then
    failed=false
    while IFS= read -r -d '' file; do
      # Single-character regex classes retain the underlying identifier.
      if sed -E 's/\[([[:alnum:].])\]/\1/g' "$file" | grep -F -f "$work/rules" >/dev/null; then
        printf 'Private source rule matched: %s (value withheld)\n' "$file" >&2
        failed=true
      else
        result=$?
        [[ $result == 1 ]] || { echo 'Private source scan failed' >&2; exit 1; }
      fi
    done <"$work/files"
    [[ "$failed" == false ]] || exit 1
  fi
fi
echo 'PASS: source credential patterns and tracked private inputs checked'
