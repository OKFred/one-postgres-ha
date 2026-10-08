#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/project/.local" "$WORK/bin"
cp "$ROOT/ops.sh" "$WORK/project/"
printf 'all: {}\n' >"$WORK/project/.local/inventory.yml"
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $1 == run ]]; then printf '%s\0' "$@" >"$SETTINGS_ARGS"; fi
MOCK
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" SETTINGS_ARGS="$WORK/arguments"
unset HA_TOOLS_IMAGE HA_SSH_KEY HA_INVENTORY
settings="$WORK/project/.local/controller.env"
saved_image="registry.example.com/tools@sha256:$(printf 'a%.0s' {1..64})"
printf 'private-key-fixture\n' >"$WORK/key with spaces"
printf 'HA_TOOLS_IMAGE=%s\nHA_SSH_KEY=%s\n' "$saved_image" "$WORK/key with spaces" >"$settings"
bash "$WORK/project/ops.sh" status
mapfile -d '' args <"$SETTINGS_ARGS"
printf '%s\n' "${args[@]}" | grep -Fxq "$saved_image"
printf '%s\n' "${args[@]}" | grep -Fxq "type=bind,src=$WORK/key with spaces,dst=/ssh-key,readonly"

# Explicit environment settings win over the saved image/key.
printf 'other-key-fixture\n' >"$WORK/other-key"
HA_TOOLS_IMAGE=one-postgres-ha-tools:override HA_SSH_KEY="$WORK/other-key" bash "$WORK/project/ops.sh" status
mapfile -d '' args <"$SETTINGS_ARGS"
printf '%s\n' "${args[@]}" | grep -Fxq one-postgres-ha-tools:override
printf '%s\n' "${args[@]}" | grep -Fxq "type=bind,src=$WORK/other-key,dst=/ssh-key,readonly"

expect_rejection() {
  rm -f -- "$SETTINGS_ARGS"
  if bash "$WORK/project/ops.sh" status >"$WORK/output" 2>&1; then
    echo 'Unsafe controller settings were accepted' >&2
    exit 1
  fi
  [[ ! -e "$SETTINGS_ARGS" && ! -e "$WORK/executed" ]]
}

# Treat the file as data even when it contains shell substitutions or array keys.
printf 'HA_TOOLS_IMAGE=$(touch %s)\n' "$WORK/executed" >"$settings"
expect_rejection
printf '$(touch %s)=value\n' "$WORK/executed" >"$settings"
expect_rejection
printf 'HA_SSH_KEY=/$(touch %s)\n' "$WORK/executed" >"$settings"
expect_rejection
printf 'HA_TOOLS_IMAGE=namespace/tools@sha256:%s\n' "$(printf 'a%.0s' {1..64})" >"$settings"
expect_rejection
printf 'HA_TOOLS_IMAGE=%s\nHA_TOOLS_IMAGE=%s\n' "$saved_image" "$saved_image" >"$settings"
expect_rejection
printf '=invalid\n' >"$settings"
expect_rejection
printf 'HA_SSH_KEY=/a,readonly\n' >"$settings"
expect_rejection
rm -f -- "$settings"
printf 'HA_TOOLS_IMAGE=%s\n' "$saved_image" >"$WORK/linked-settings"
ln -s "$WORK/linked-settings" "$settings"
expect_rejection

echo 'PASS: persisted controller settings, explicit overrides and non-executable private config'
