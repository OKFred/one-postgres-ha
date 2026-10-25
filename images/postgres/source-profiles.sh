#!/usr/bin/env bash
# Shared, public package-source presets. Sourcing this file changes no files.
# Public URL outputs are consumed by the controller and host-preparation scripts.
# shellcheck disable=SC2034
ha_source_urls() {
  case "${1:-}" in
    official)
      HA_DEBIAN_URL=https://deb.debian.org/debian
      HA_DEBIAN_SECURITY_URL=https://deb.debian.org/debian-security
      HA_PYPI_URL=https://pypi.org/simple
      HA_DOCKER_CE_URL=https://download.docker.com ;;
    ustc)
      HA_DEBIAN_URL=https://mirrors.ustc.edu.cn/debian
      HA_DEBIAN_SECURITY_URL=https://mirrors.ustc.edu.cn/debian-security
      HA_PYPI_URL=https://mirrors.ustc.edu.cn/pypi/simple
      HA_DOCKER_CE_URL=https://mirrors.ustc.edu.cn/docker-ce ;;
    tuna)
      HA_DEBIAN_URL=https://mirrors.tuna.tsinghua.edu.cn/debian
      HA_DEBIAN_SECURITY_URL=https://mirrors.tuna.tsinghua.edu.cn/debian-security
      HA_PYPI_URL=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
      HA_DOCKER_CE_URL=https://mirrors.tuna.tsinghua.edu.cn/docker-ce ;;
    *) printf 'Unknown package source; choose official, ustc or tuna.\n' >&2; return 2 ;;
  esac
}

ha_source_validate_deb822() {
  local file=$1 kind=$2
  awk -v kind="$kind" '
    /^[[:space:]]*(#|$)/ {next}
    /^URIs:/ {
      if (NF != 2) exit 1
      if (kind == "pgdg") {
        if ($2 !~ /^https?:\/\/apt\.postgresql\.org\/pub\/repos\/apt\/?$/) exit 1
      } else if ($2 !~ /^https?:\/\/(deb\.debian\.org|security\.debian\.org|mirrors\.ustc\.edu\.cn|mirrors\.tuna\.tsinghua\.edu\.cn)\/debian(-security)?\/?$/) exit 1
      found++; next
    }
    /^Signed-By:/ {
      expected=(kind == "pgdg" ? "/usr/local/share/keyrings/postgres.gpg.asc" : "/usr/share/keyrings/debian-archive-keyring.gpg")
      if (NF != 2 || $2 != expected) exit 1
      next
    }
    /^(Types|Suites|Components|Architectures|Enabled):/ {next}
    {exit 1}
    END {if (!found) exit 1}
  ' "$file"
}

ha_source_write_debian() {
  local input=$1 output=$2 debian=$3 security=$4
  awk -v debian="$debian" -v security="$security" '
    /^URIs:/ {print "URIs: " ($2 ~ /\/debian-security\/?$/ ? security : debian); next}
    {print}
  ' "$input" >"$output" || return
  chmod 0644 "$output"
}

# Only container builds call this function. A fixture can supply an isolated root.
ha_source_apply() {
  local profile=$1 root=${2:-/} directory source original path ca has_ca=false
  ha_source_urls "$profile" || return
  [[ "$profile" != official ]] || return 0
  [[ "$root" == /* && ! -L "$root" ]] || return 2
  [[ "$root" == / || $(realpath -e -- "$root") == "${root%/}" ]] || return 2
  root=${root%/}
  directory="$root/etc/apt/sources.list.d"
  source="$directory/debian.sources"
  for path in "$root/etc" "$root/etc/apt" "$directory" "$source"; do
    [[ -e "$path" && ! -L "$path" ]] || { printf 'Unsafe or missing container APT path.\n' >&2; return 2; }
  done
  [[ -f "$source" && $(stat -c %h -- "$source") == 1 ]] && ha_source_validate_deb822 "$source" debian || {
    printf 'Unknown Debian source format; container sources were preserved.\n' >&2; return 2;
  }
  if [[ -e "$root/etc/apt/sources.list" || -L "$root/etc/apt/sources.list" ]]; then
    [[ -f "$root/etc/apt/sources.list" && ! -L "$root/etc/apt/sources.list" ]] || return 2
    ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$root/etc/apt/sources.list" || return 2
  fi
  # The pinned PostgreSQL binary is already installed. Do not contact unused PGDG.
  for path in "$directory"/*.list "$directory"/*.sources; do
    [[ -e "$path" || -L "$path" ]] || continue
    [[ -f "$path" && ! -L "$path" && $(stat -c %h -- "$path") == 1 ]] || return 2
    case "${path##*/}" in
      debian.sources) ;;
      pgdg.sources) ha_source_validate_deb822 "$path" pgdg || return 2 ;;
      pgdg.list)
        awk '
          /^[[:space:]]*(#|$)/ {next}
          $1 !~ /^deb(-src)?$/ {exit 1}
          {count=0; for(i=1;i<=NF;i++) if ($i ~ /:\/\//) {
            if ($i !~ /^https?:\/\/apt\.postgresql\.org\/pub\/repos\/apt\/?$/) exit 1
            count++
          }; if(count!=1) exit 1}
        ' "$path" || return 2 ;;
      *)
        ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$path" || {
          printf 'Unknown active container APT source; sources were preserved.\n' >&2; return 2;
        } ;;
    esac
  done
  ca="$root/etc/ssl/certs/ca-certificates.crt"
  for path in "$root/etc/ssl" "$root/etc/ssl/certs"; do
    [[ ! -L "$path" ]] || return 2
  done
  [[ ! -L "$ca" ]] || return 2
  [[ ! -e "$ca" || ( -f "$ca" && $(stat -c %h -- "$ca") == 1 ) ]] || return 2
  [[ ! -s "$ca" ]] || has_ca=true
  if [[ -n "$root" && "$has_ca" != true ]]; then
    # An isolated fixture must never invoke the host package manager accidentally.
    declare -F apt-get >/dev/null || { printf 'Fixture CA bootstrap requires an isolated APT stub.\n' >&2; return 2; }
  fi
  original=$(mktemp "$directory/.ha-debian.XXXXXXXX") || return
  cp -- "$source" "$original" || { rm -f -- "$original"; return 2; }
  if [[ "$has_ca" == true ]]; then
    ha_source_write_debian "$original" "$source" "$HA_DEBIAN_URL" "$HA_DEBIAN_SECURITY_URL" || { rm -f -- "$original"; return 2; }
  else
    # Bootstrap only the CA package through Debian-signed APT metadata/packages.
    # No insecure/trusted APT options are enabled. All subsequent traffic is HTTPS.
    ha_source_write_debian "$original" "$source" "${HA_DEBIAN_URL/https:/http:}" "${HA_DEBIAN_SECURITY_URL/https:/http:}" || {
      rm -f -- "$original"; return 2;
    }
  fi
  rm -f -- "$directory/pgdg.list" "$directory/pgdg.sources" || { rm -f -- "$original"; return 2; }
  if [[ "$has_ca" != true ]]; then
    if ! apt-get update || ! apt-get install -y --no-install-recommends ca-certificates || [[ ! -s "$ca" ]]; then
      cp -- "$original" "$source"
      rm -f -- "$original"
      printf 'Container CA bootstrap failed; no TLS verification was disabled.\n' >&2
      return 2
    fi
    ha_source_write_debian "$original" "$source" "$HA_DEBIAN_URL" "$HA_DEBIAN_SECURITY_URL" || { rm -f -- "$original"; return 2; }
  fi
  rm -f -- "$original"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -Eeuo pipefail
  [[ $# == 2 ]] || { printf 'Usage: source-profiles.sh --pip-url|--apply PROFILE\n' >&2; exit 2; }
  case "$1" in
    --pip-url) ha_source_urls "$2"; printf '%s\n' "$HA_PYPI_URL" ;;
    --apply)
      [[ $(id -u) == 0 && ${PG_MAJOR:-} == 17 && -x /usr/lib/postgresql/17/bin/postgres &&
         -f /usr/local/bin/docker-entrypoint.sh ]] || {
        printf 'Source application is restricted to the pinned PostgreSQL container build.\n' >&2; exit 2;
      }
      ha_source_apply "$2" ;;
    *) exit 2 ;;
  esac
fi
