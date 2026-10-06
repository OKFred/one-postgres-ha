#!/usr/bin/env bash
set -Eeuo pipefail
exec curl --fail --silent --show-error --max-time 4 "${PATRONI_HEALTHCHECK_URL:-http://127.0.0.1:8008/liveness}" >/dev/null
