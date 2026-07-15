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

configure_nvmet_subsystem() {
  local subsys_path="/sys/kernel/config/nvmet/subsystems/${NQN}"
  mkdir -p "${subsys_path}"
  echo 1 > "${subsys_path}/attr_allow_any_host"

  local i img loop_dev ns_path current_path current_enable
  for ((i=1; i<=NUM_DRIVES; i++)); do
    img="${BASE_DIR}/${IMAGE_PREFIX}${i}.img"
    loop_dev="$(ensure_loop_for_image "${img}")"
    ns_path="${subsys_path}/namespaces/${i}"
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
  done
}

configure_nvmet_port() {
  local port_path="/sys/kernel/config/nvmet/ports/${PORT_ID}"
  mkdir -p "${port_path}"
  echo -n loop > "${port_path}/addr_trtype"

  local link_path="${port_path}/subsystems/${NQN}"
  if [[ ! -L "${link_path}" ]]; then
    ln -s "/sys/kernel/config/nvmet/subsystems/${NQN}" "${link_path}"
  fi
}

connect_local_nvme_host() {
  need_cmd nvme
  if nvme list-subsys 2>/dev/null | grep -Fq "NQN=${NQN}"; then
    return
  fi
  nvme connect -t loop -n "${NQN}"
}

print_summary() {
  echo "NVMe emulation configured."
  echo "NQN: ${NQN}"
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

  ensure_configfs_mounted
  load_modules
  create_backing_images
  configure_nvmet_subsystem
  configure_nvmet_port
  connect_local_nvme_host
  print_summary
}

main "$@"
