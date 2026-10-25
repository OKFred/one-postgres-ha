#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mapfile -d '' scripts < <(find ops.sh menu.sh install.sh uninstall.sh scripts images tests -type f -name '*.sh' -print0)
for script in "${scripts[@]}"; do bash -n "$script"; done
shellcheck -S warning "${scripts[@]}"
yamllint docker-compose.yml
yamllint ansible .github images/tools/collections.yml
# Run Ansible discovery on the container filesystem; Windows bind traversal is slow.
lint_root=$(mktemp -d)
trap 'rm -rf -- "$lint_root"' EXIT
cp -R ansible config images .ansible-lint .yamllint.yml "$lint_root/"
(
  cd "$lint_root"
  export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"
  ansible-lint --offline ansible
  for playbook in ansible/*.yml ansible/data/main.yml; do
    [[ -f "$playbook" ]] || continue
    [[ "$playbook" != ansible/inventory.example.yml ]] || continue
    ansible-playbook -i ansible/inventory.example.yml "$playbook" --syntax-check \
      -e project_root="$PWD" -e private_dir="$PWD/.local" \
      -e add_node=replica04 -e ha_data_operation=backup -e ha_data_database=one_minihouse
  done
)
bash tests/test-cli.sh
bash tests/test-configure.sh
python3 -B tests/test-configure-probe.py
bash tests/test-architecture-preflight.sh
bash tests/test-topology.sh
bash tests/test-controller-settings.sh
bash tests/test-download-sources.sh
bash tests/test-package-sources.sh
bash tests/test-download-wiring.sh
bash tests/test-publish-images.sh
bash tests/test-entrypoints.sh
bash tests/test-menu.sh
bash tests/test-prebuilt-images.sh
bash tests/test-postgres-baseline.sh
bash tests/test-postgres-major-guard.sh
bash tests/test-cleanup-node.sh
bash tests/test-retained-recovery.sh
bash tests/test-secrets.sh
bash tests/test-controller.sh
bash tests/test-peer-routes.sh
bash tests/test-primary-update.sh
bash tests/test-switchover-gate.sh
bash tests/test-proxy-start.sh
bash tests/test-host-mounts.sh
bash tests/test-host-tools.sh
bash tests/test-host-architecture.sh
bash tests/test-native-probe.sh
bash tests/test-local-replication.sh
bash tests/test-backup-ownership.sh
bash scripts/data/test-versions.sh
bash scripts/data/test-acceptance.sh
bash tests/test-firewall-gate.sh
bash tests/test-source-scan.sh
bash tests/test-public-export.sh
bash tests/scan-secrets.sh
