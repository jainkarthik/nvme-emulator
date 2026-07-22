#!/usr/bin/env bash
set -euo pipefail

# Emulate 6 persistent 20GB NVMe drives on host using:
# backing files -> loop devices -> nvmet namespaces -> nvme loop connection
#
# This script intentionally does NOT partition/format/mount anything.

NUM_DRIVES="${NUM_DRIVES:-6}"
DRIVE_SIZE_GB="${DRIVE_SIZE_GB:-20}"
BASE_DIR="${BASE_DIR:-/var/lib/nvme-emu}"
IMAGE_PREFIX="${IMAGE_PREFIX:-nvme-drive}"
NQN="${NQN:-nqn.2026-07.local.host:nvme-emu}"
PORT_ID="${PORT_ID:-1}"
UNIQUE_SERIALS="${UNIQUE_SERIALS:-1}"
SERIAL_PREFIX="${SERIAL_PREFIX:-NVMEEMU}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root" >&2
    exit 1
  fi
}

need_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: missing command: ${cmd}" >&2
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
  validate_positive_int DRIVE_SIZE_GB "${DRIVE_SIZE_GB}"
  validate_positive_int PORT_ID "${PORT_ID}"

  if [[ -z "${BASE_DIR}" ]]; then
    echo "ERROR: BASE_DIR must not be empty" >&2
    exit 1
  fi

  if [[ -z "${NQN}" || "${NQN}" == *"/"* ]]; then
    echo "ERROR: NQN must be non-empty and must not contain '/'" >&2
    exit 1
  fi

  if [[ "${UNIQUE_SERIALS}" != "0" && "${UNIQUE_SERIALS}" != "1" ]]; then
    echo "ERROR: UNIQUE_SERIALS must be 0 or 1" >&2
    exit 1
  fi

  if (( ${#SERIAL_PREFIX} > 14 )); then
    echo "ERROR: SERIAL_PREFIX must be at most 14 characters" >&2
    exit 1
  fi
}

ensure_configfs_mounted() {
  if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config
  fi
}

load_modules() {
  modprobe loop
  modprobe nvmet
  modprobe nvme_loop
}

create_backing_images() {
  mkdir -p "${BASE_DIR}"
  local i img
  for ((i=1; i<=NUM_DRIVES; i++)); do
    img="${BASE_DIR}/${IMAGE_PREFIX}${i}.img"
    if [[ ! -f "${img}" ]]; then
      truncate -s "${DRIVE_SIZE_GB}G" "${img}"
    fi
  done
}

ensure_loop_for_image() {
  local img="$1"
  local loop_dev
  loop_dev="$(losetup -j "${img}" | awk -F: 'NR==1 {print $1}')"
  if [[ -n "${loop_dev}" ]]; then
    echo "${loop_dev}"
    return
  fi
  losetup --find --show "${img}"
}

subsystem_nqn_for_drive() {
  local i="$1"
  if [[ "${UNIQUE_SERIALS}" == "1" ]]; then
    echo "${NQN}:${i}"
  else
    echo "${NQN}"
  fi
}

namespace_id_for_drive() {
  local i="$1"
  if [[ "${UNIQUE_SERIALS}" == "1" ]]; then
    echo "1"
  else
    echo "${i}"
  fi
}

serial_for_drive() {
  local i="$1"
  printf "%s%06d" "${SERIAL_PREFIX}" "${i}"
}

teardown_subsystem_nqn() {
  local target_nqn="$1"
  local subsys_path="/sys/kernel/config/nvmet/subsystems/${target_nqn}"
  local port_path="/sys/kernel/config/nvmet/ports/${PORT_ID}"

  if [[ -L "${port_path}/subsystems/${target_nqn}" ]]; then
    rm -f "${port_path}/subsystems/${target_nqn}"
  fi

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
}

prune_stale_namespaces() {
  local subsys_path="$1"
  local ns ns_name
  shopt -s nullglob
  for ns in "${subsys_path}"/namespaces/*; do
    [[ -d "${ns}" ]] || continue
    ns_name="${ns##*/}"
    if [[ "${ns_name}" =~ ^[0-9]+$ ]] && (( ns_name > NUM_DRIVES )); then
      if [[ -f "${ns}/enable" ]]; then
        echo 0 > "${ns}/enable" || true
      fi
      rmdir "${ns}" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}

prune_stale_unique_subsystems() {
  local subsys_root="/sys/kernel/config/nvmet/subsystems"
  local path name suffix
  shopt -s nullglob
  for path in "${subsys_root}/${NQN}:"*; do
    [[ -d "${path}" ]] || continue
    name="${path##*/}"
    suffix="${name#${NQN}:}"
    if [[ "${suffix}" =~ ^[0-9]+$ ]] && (( suffix > NUM_DRIVES )); then
      teardown_subsystem_nqn "${name}"
    fi
  done
  shopt -u nullglob
}

configure_nvmet_port() {
  local port_path="/sys/kernel/config/nvmet/ports/${PORT_ID}"
  mkdir -p "${port_path}"
  mkdir -p "${port_path}/subsystems"
  local trtype_path="${port_path}/addr_trtype"
  local current_trtype=""
  if [[ -f "${trtype_path}" ]]; then
    current_trtype="$(cat "${trtype_path}" 2>/dev/null || true)"
  fi

  if [[ -z "${current_trtype}" ]]; then
    echo -n loop > "${trtype_path}"
  elif [[ "${current_trtype}" != "loop" ]]; then
    echo "ERROR: port ${PORT_ID} transport is '${current_trtype}', expected 'loop'." >&2
    echo "Run teardown and then setup again, or use a different PORT_ID." >&2
    exit 1
  fi
}

ensure_port_link_for_nqn() {
  local target_nqn="$1"
  local port_path="/sys/kernel/config/nvmet/ports/${PORT_ID}"
  local link_path="${port_path}/subsystems/${target_nqn}"
  local subsys_path="/sys/kernel/config/nvmet/subsystems/${target_nqn}"

  if [[ -L "${link_path}" ]]; then
    if [[ "$(readlink "${link_path}")" != "${subsys_path}" ]]; then
      rm -f "${link_path}"
    fi
  elif [[ -e "${link_path}" ]]; then
    rm -rf "${link_path}"
  fi

  if [[ ! -L "${link_path}" ]]; then
    ln -s "${subsys_path}" "${link_path}"
  fi
}

ensure_subsystem_serial() {
  local subsys_path="$1"
  local serial="$2"
  local serial_path="${subsys_path}/attr_serial"
  local current_serial=""

  if [[ -f "${serial_path}" ]]; then
    current_serial="$(awk '{print $1}' "${serial_path}" 2>/dev/null || true)"
  fi

  if [[ "${current_serial}" != "${serial}" ]]; then
    if ! echo -n "${serial}" > "${serial_path}"; then
      echo "ERROR: failed to set subsystem serial to '${serial}' at ${serial_path}." >&2
      echo "Run teardown and then setup again, or disable UNIQUE_SERIALS." >&2
      exit 1
    fi
  fi

  current_serial="$(awk '{print $1}' "${serial_path}" 2>/dev/null || true)"
  if [[ "${current_serial}" != "${serial}" ]]; then
    echo "ERROR: subsystem serial is '${current_serial}', expected '${serial}'." >&2
    echo "Run teardown and then setup again, or use a different NQN." >&2
    exit 1
  fi
}

configure_nvmet_for_drive() {
  local i="$1"
  local target_nqn nsid serial
  target_nqn="$(subsystem_nqn_for_drive "${i}")"
  nsid="$(namespace_id_for_drive "${i}")"
  serial="$(serial_for_drive "${i}")"

  local subsys_path="/sys/kernel/config/nvmet/subsystems/${target_nqn}"
  mkdir -p "${subsys_path}"
  echo 1 > "${subsys_path}/attr_allow_any_host"

  if [[ "${UNIQUE_SERIALS}" == "1" ]]; then
    ensure_subsystem_serial "${subsys_path}" "${serial}"
  else
    prune_stale_namespaces "${subsys_path}"
  fi

  local img loop_dev ns_path current_path current_enable
  img="${BASE_DIR}/${IMAGE_PREFIX}${i}.img"
  loop_dev="$(ensure_loop_for_image "${img}")"
  ns_path="${subsys_path}/namespaces/${nsid}"
  mkdir -p "${ns_path}"

  current_path=""
  if [[ -f "${ns_path}/device_path" ]]; then
    current_path="$(cat "${ns_path}/device_path" 2>/dev/null || true)"
  fi
  current_enable=0
  if [[ -f "${ns_path}/enable" ]]; then
    current_enable="$(cat "${ns_path}/enable" 2>/dev/null || echo 0)"
  fi

  if [[ "${current_enable}" == "1" && "${current_path}" != "${loop_dev}" ]]; then
    echo 0 > "${ns_path}/enable"
  fi
  if [[ "${current_path}" != "${loop_dev}" ]]; then
    echo -n "${loop_dev}" > "${ns_path}/device_path"
  fi
  echo 1 > "${ns_path}/enable"

  ensure_port_link_for_nqn "${target_nqn}"
}

connect_local_nvme_host_for_nqn() {
  local target_nqn="$1"
  need_cmd nvme
  if nvme list-subsys 2>/dev/null | grep -Fq "NQN=${target_nqn}"; then
    return
  fi
  nvme connect -t loop -n "${target_nqn}"
}

print_summary() {
  echo "NVMe emulation configured."
  if [[ "${UNIQUE_SERIALS}" == "1" ]]; then
    echo "NQN base: ${NQN} (using ${NQN}:{1..${NUM_DRIVES}})"
    echo "Serials: ${SERIAL_PREFIX}000001..${SERIAL_PREFIX}$(printf "%06d" "${NUM_DRIVES}")"
  else
    echo "NQN: ${NQN}"
  fi
  echo "Images: ${BASE_DIR}/${IMAGE_PREFIX}{1..${NUM_DRIVES}}.img (${DRIVE_SIZE_GB}G each)"
  echo "Run: nvme list"
}

main() {
  require_root
  need_cmd losetup
  need_cmd truncate
  need_cmd modprobe
  need_cmd mountpoint
  need_cmd awk
  need_cmd grep
  need_cmd cat
  need_cmd ln
  need_cmd readlink

  validate_inputs
  ensure_configfs_mounted
  load_modules
  create_backing_images
  configure_nvmet_port
  if [[ "${UNIQUE_SERIALS}" == "1" ]]; then
    prune_stale_unique_subsystems
  fi

  local i target_nqn
  for ((i=1; i<=NUM_DRIVES; i++)); do
    configure_nvmet_for_drive "${i}"
    target_nqn="$(subsystem_nqn_for_drive "${i}")"
    connect_local_nvme_host_for_nqn "${target_nqn}"
  done

  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
