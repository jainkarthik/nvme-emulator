#!/usr/bin/env bash
set -euo pipefail

# Teardown emulated NVMe stack created by setup_nvme_emu.sh
# Keeps backing image files by default.

NUM_DRIVES="${NUM_DRIVES:-6}"
BASE_DIR="${BASE_DIR:-/var/lib/nvme-emu}"
IMAGE_PREFIX="${IMAGE_PREFIX:-nvme-drive}"
NQN="${NQN:-nqn.2026-07.local.host:nvme-emu}"
PORT_ID="${PORT_ID:-1}"

DESTROY_IMAGES="${DESTROY_IMAGES:-0}" # set to 1 to delete backing files

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root" >&2
    exit 1
  fi
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${name} must be a positive integer" >&2
    exit 1
  fi
}

validate_inputs() {
  validate_positive_int NUM_DRIVES "${NUM_DRIVES}"
  validate_positive_int PORT_ID "${PORT_ID}"

  if [[ -z "${BASE_DIR}" ]]; then
    echo "ERROR: BASE_DIR must not be empty" >&2
    exit 1
  fi

  if [[ -z "${NQN}" || "${NQN}" == *"/"* ]]; then
    echo "ERROR: NQN must be non-empty and must not contain '/'" >&2
    exit 1
  fi
}

disconnect_nvme_host() {
  if command -v nvme >/dev/null 2>&1; then
    nvme disconnect -n "${NQN}" >/dev/null 2>&1 || true
  fi
}

teardown_nvmet() {
  local subsys_path="/sys/kernel/config/nvmet/subsystems/${NQN}"
  local port_path="/sys/kernel/config/nvmet/ports/${PORT_ID}"

  if [[ -L "${port_path}/subsystems/${NQN}" ]]; then
    unlink "${port_path}/subsystems/${NQN}" 2>/dev/null || rm -f "${port_path}/subsystems/${NQN}"
  fi
  rmdir "${port_path}/subsystems" 2>/dev/null || true

  if [[ -d "${subsys_path}/namespaces" ]]; then
    local ns
    shopt -s nullglob
    for ns in "${subsys_path}"/namespaces/*; do
      [[ -d "${ns}" ]] || continue
      if [[ -f "${ns}/enable" ]]; then
        echo 0 > "${ns}/enable" || true
      fi
      rmdir "${ns}" 2>/dev/null || true
    done
    shopt -u nullglob
  fi

  rmdir "${subsys_path}" 2>/dev/null || true
  rmdir "${port_path}" 2>/dev/null || true
}

detach_loops() {
  local i img loop_dev
  for ((i=1; i<=NUM_DRIVES; i++)); do
    img="${BASE_DIR}/${IMAGE_PREFIX}${i}.img"
    if [[ -f "${img}" ]]; then
      loop_dev="$(losetup -j "${img}" | awk -F: 'NR==1 {print $1}')"
      if [[ -n "${loop_dev}" ]]; then
        losetup -d "${loop_dev}" || true
      fi
      if [[ "${DESTROY_IMAGES}" == "1" ]]; then
        rm -f "${img}"
      fi
    fi
  done
}

main() {
  require_root
  validate_inputs
  disconnect_nvme_host
  teardown_nvmet
  detach_loops
  echo "NVMe emulation torn down. Backing images kept: $([[ "${DESTROY_IMAGES}" == "1" ]] && echo no || echo yes)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
