#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $# -eq 2 ]] || { echo 'Usage: bootstrap-secrets.sh INVENTORY SECRET_DIR' >&2; exit 2; }
inventory=$1
directory=$2
mkdir -p "$directory"
exec 9>"$directory/.lock"
flock -n 9 || { echo 'Credential preparation is already running' >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
ansible-inventory -i "$inventory" --list >"$tmp/inventory.json"
jq -er '
  def hosts($g): (.[$g].hosts // []) + [(.[$g].children // [])[] as $c | hosts($c)[]];
  . as $i | hosts("pg_nodes") | unique[] as $h |
  [$i._meta.hostvars[$h].node_name, $i._meta.hostvars[$h].node_ip] |
  select(all(.[]; type == "string" and length > 0)) | @tsv
' "$tmp/inventory.json" >"$tmp/nodes"
[[ -s "$tmp/nodes" ]] || { echo 'Inventory has no configured pg_nodes' >&2; exit 2; }
if [[ -e "$directory/ca.crt" || -e "$directory/ca.key" ]]; then
  [[ -s "$directory/ca.crt" && -s "$directory/ca.key" ]] || {
    echo 'Incomplete existing CA; restore its matching key/certificate, do not recreate it' >&2; exit 2;
  }
  openssl x509 -in "$directory/ca.crt" -noout -checkend 2592000 >/dev/null
  openssl x509 -in "$directory/ca.crt" -pubkey -noout >"$tmp/cert.pub"
  openssl pkey -in "$directory/ca.key" -pubout >"$tmp/key.pub"
  cmp -s "$tmp/cert.pub" "$tmp/key.pub" || { echo 'CA key mismatch' >&2; exit 2; }
else
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$tmp/ca.key" -out "$tmp/ca.crt" -days 3650 \
    -subj '/CN=one-postgres-ha private CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>"$tmp/openssl.log"
  install -m 0600 "$tmp/ca.key" "$directory/ca.key"
  install -m 0644 "$tmp/ca.crt" "$directory/ca.crt"
fi
for password in postgres-password replication-password rewind-password patroni-api-password; do
  if [[ -e "$directory/$password" ]]; then
    [[ -s "$directory/$password" ]] || { echo "Empty existing credential: $password" >&2; exit 2; }
  else
    openssl rand -base64 32 >"$tmp/password"
    install -m 0600 "$tmp/password" "$directory/$password"
  fi
done
while IFS=$'\t' read -r name ip; do
  [[ "$name" =~ ^[a-z][a-z0-9_-]{0,62}$ && "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || {
    echo 'Invalid node name/address' >&2; exit 2;
  }
  mkdir -p "$directory/$name"
  for purpose in etcd patroni; do
    cert="$directory/$name/$purpose.crt"
    key="$directory/$name/$purpose.key"
    if [[ -e "$cert" || -e "$key" ]]; then
      [[ -s "$cert" && -s "$key" ]] || { echo "Incomplete certificate for $name/$purpose" >&2; exit 2; }
      openssl verify -CAfile "$directory/ca.crt" "$cert" >/dev/null
      openssl x509 -in "$cert" -noout -checkip "$ip" >/dev/null
      openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null
      openssl x509 -in "$cert" -pubkey -noout >"$tmp/cert.pub"
      openssl pkey -in "$key" -pubout >"$tmp/key.pub"
      cmp -s "$tmp/cert.pub" "$tmp/key.pub" || { echo "Key mismatch: $name/$purpose" >&2; exit 2; }
      continue
    fi
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$tmp/node.key" -out "$tmp/node.csr" -subj "/CN=$name-$purpose" 2>"$tmp/openssl.log"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:%s,IP:127.0.0.1,DNS:%s,DNS:localhost\n' "$ip" "$name" >"$tmp/extensions"
    openssl x509 -req -in "$tmp/node.csr" -CA "$directory/ca.crt" -CAkey "$directory/ca.key" \
      -set_serial "0x$(openssl rand -hex 16)" -out "$tmp/node.crt" -days 365 \
      -extfile "$tmp/extensions" 2>"$tmp/openssl.log"
    install -m 0600 "$tmp/node.key" "$key"
    install -m 0644 "$tmp/node.crt" "$cert"
  done
done <"$tmp/nodes"
echo 'Credentials and certificates prepared. Existing values were preserved.'
