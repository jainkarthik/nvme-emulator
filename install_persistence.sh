#!/usr/bin/env bash
set -euo pipefail

# Install scripts + systemd service so emulated NVMe devices are recreated at boot.
# This script does not format/mount devices.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root" >&2
    exit 1
  fi
}

main() {
  require_root

  install -m 0755 "${SCRIPT_DIR}/setup_nvme_emu.sh" /usr/local/sbin/setup_nvme_emu.sh
  install -m 0755 "${SCRIPT_DIR}/teardown_nvme_emu.sh" /usr/local/sbin/teardown_nvme_emu.sh
  install -m 0644 "${SCRIPT_DIR}/nvme-emu.service" /etc/systemd/system/nvme-emu.service

  mkdir -p /etc/modules-load.d
  cat > /etc/modules-load.d/nvme-emu.conf <<'EOF'
loop
nvmet
nvme_loop
EOF

  systemctl daemon-reload
  systemctl enable nvme-emu.service
  systemctl start nvme-emu.service

  echo "Installed and started nvme-emu.service"
}

main "$@"
