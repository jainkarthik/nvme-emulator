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

install_files() {
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
}

uninstall_files() {
  systemctl disable --now nvme-emu.service >/dev/null 2>&1 || true
  rm -f /usr/local/sbin/setup_nvme_emu.sh
  rm -f /usr/local/sbin/teardown_nvme_emu.sh
  rm -f /etc/systemd/system/nvme-emu.service
  rm -f /etc/modules-load.d/nvme-emu.conf
  systemctl daemon-reload
}

main() {
  require_root

  case "${1:-install}" in
    install)
      if install_files; then
        echo "Installed and started nvme-emu.service"
      else
        uninstall_files
        exit 1
      fi
      ;;
    uninstall)
      uninstall_files
      echo "Uninstalled nvme-emu.service"
      ;;
    *)
      echo "Usage: $0 [install|uninstall]" >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
