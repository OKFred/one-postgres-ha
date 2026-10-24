#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# Execute the actual architecture gate and source rendering in isolation. No host
# configuration, package manager or service command from prepare-host is run.
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, re, sys

root, work = map(pathlib.Path, sys.argv[1:])
text = (root / 'scripts/prepare-host.sh').read_text()
gate = re.search(r'^ARCHITECTURE=\$\(dpkg --print-architecture\)\ncase .*?^esac$', text, re.M | re.S)
source = re.search(r'^REPO_TEXT=.*$', text, re.M)
assert gate and source
(work / 'detect.sh').write_text(gate.group() + '\n' + source.group() + '\n')
PY

die() { printf '%s\n' "$1" >&2; exit 2; }
dpkg() {
  [[ $# == 1 && $1 == --print-architecture ]] || die 'Unexpected package manager invocation'
  printf '%s\n' "$TEST_ARCHITECTURE"
}

for TEST_ARCHITECTURE in amd64 arm64; do
  (
    source "$WORK/detect.sh"
    [[ $ARCHITECTURE == "$TEST_ARCHITECTURE" ]]
    grep -Fxq "Architectures: $TEST_ARCHITECTURE" <<<"$REPO_TEXT"
    grep -Fxq 'Suites: trixie' <<<"$REPO_TEXT"
    grep -Fxq 'Signed-By: /etc/apt/keyrings/docker.asc' <<<"$REPO_TEXT"
  )
done

for TEST_ARCHITECTURE in i386 armhf riscv64 ppc64el '' 'amd64 arm64'; do
  if (source "$WORK/detect.sh") >"$WORK/rejected" 2>&1; then
    die "Unsupported host architecture was accepted: $TEST_ARCHITECTURE"
  fi
  grep -Fq 'Only AMD64 and ARM64 host packages are supported' "$WORK/rejected"
done

bash "$ROOT/scripts/prepare-host.sh" --help >"$WORK/help"
grep -Fq 'Debian 13 AMD64 or ARM64' "$WORK/help"
echo 'PASS: host preparation detects AMD64/ARM64, renders the matching Docker source and rejects other architectures'
