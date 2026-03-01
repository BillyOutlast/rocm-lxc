#!/usr/bin/env bash
set -euo pipefail

msg_info() { printf "[INFO] %s\n" "$1"; }
msg_ok() { printf "[OK] %s\n" "$1"; }
msg_warn() { printf "[WARN] %s\n" "$1"; }
msg_error() { printf "[ERROR] %s\n" "$1"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    msg_error "Missing required command: $1"
    exit 1
  }
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local value
  read -r -p "${prompt} [${default_value}]: " value
  if [[ -z "${value}" ]]; then
    printf "%s" "${default_value}"
  else
    printf "%s" "${value}"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default_yes="$2"
  local value
  local suffix="[y/N]"
  if [[ "${default_yes}" == "yes" ]]; then
    suffix="[Y/n]"
  fi
  read -r -p "${prompt} ${suffix}: " value
  value="${value,,}"
  if [[ -z "${value}" ]]; then
    [[ "${default_yes}" == "yes" ]] && return 0 || return 1
  fi
  [[ "${value}" == "y" || "${value}" == "yes" ]]
}

if [[ "${EUID}" -ne 0 ]]; then
  msg_error "Run this script as root on a Proxmox host"
  exit 1
fi

require_cmd pct
require_cmd pvesh
require_cmd awk
require_cmd sed

DEFAULT_CTID="$(pvesh get /cluster/nextid)"
DEFAULT_TEMPLATE="local:vztmpl/rocm-dev-ubuntu-24.04-7.2-complete.tar.gz"
DEFAULT_HOSTNAME="rocm-ct-${DEFAULT_CTID}"

msg_info "ROCm LXC installer for Proxmox"

CTID="$(prompt_default "Container ID" "${DEFAULT_CTID}")"
TEMPLATE="$(prompt_default "Template volume (storage:vztmpl/name.tar.gz)" "${DEFAULT_TEMPLATE}")"
HOSTNAME="$(prompt_default "Hostname" "${DEFAULT_HOSTNAME}")"
CORES="$(prompt_default "CPU cores" "8")"
MEMORY="$(prompt_default "Memory MB" "32768")"
SWAP="$(prompt_default "Swap MB" "0")"
ROOTFS_STORAGE="$(prompt_default "Rootfs storage" "local-lvm")"
ROOTFS_SIZE="$(prompt_default "Rootfs size GB" "64")"
BRIDGE="$(prompt_default "Network bridge" "vmbr0")"
IPCFG="$(prompt_default "IP config (dhcp or cidr,gw=...)" "dhcp")"

if prompt_yes_no "Create unprivileged container" "yes"; then
  UNPRIVILEGED="1"
else
  UNPRIVILEGED="0"
fi

if prompt_yes_no "Start container after creation" "yes"; then
  START_AFTER="yes"
else
  START_AFTER="no"
fi

if prompt_yes_no "Enable AMD GPU passthrough (/dev/dri and /dev/kfd)" "yes"; then
  ENABLE_GPU="yes"
else
  ENABLE_GPU="no"
fi

if pct status "${CTID}" >/dev/null 2>&1; then
  msg_error "CT ${CTID} already exists"
  exit 1
fi

if ! pvesm path "${TEMPLATE}" >/dev/null 2>&1; then
  msg_error "Template not found in storage: ${TEMPLATE}"
  msg_info "Copy your template tarball into a storage CT template cache first"
  exit 1
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"

msg_info "Creating CT ${CTID}"
pct create "${CTID}" "${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${ROOTFS_STORAGE}:${ROOTFS_SIZE}" \
  --net0 "${NET0}" \
  --features nesting=1,keyctl=1 \
  --unprivileged "${UNPRIVILEGED}" \
  --onboot 1

CONF="/etc/pve/lxc/${CTID}.conf"

if [[ "${ENABLE_GPU}" == "yes" ]]; then
  if [[ ! -e /dev/dri ]]; then
    msg_warn "/dev/dri not found on host; skipping /dev/dri passthrough"
  else
    if ! grep -q "^lxc.cgroup2.devices.allow: c 226:\* rwm$" "${CONF}"; then
      echo "lxc.cgroup2.devices.allow: c 226:* rwm" >> "${CONF}"
    fi
    if ! grep -q "^lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir$" "${CONF}"; then
      echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> "${CONF}"
    fi
    msg_ok "Configured /dev/dri passthrough"
  fi

  if [[ ! -e /dev/kfd ]]; then
    msg_warn "/dev/kfd not found on host; skipping /dev/kfd passthrough"
  else
    if ! grep -q "^lxc.cgroup2.devices.allow: c 235:\* rwm$" "${CONF}"; then
      echo "lxc.cgroup2.devices.allow: c 235:* rwm" >> "${CONF}"
    fi
    if ! grep -q "^lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file$" "${CONF}"; then
      echo "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file" >> "${CONF}"
    fi
    msg_ok "Configured /dev/kfd passthrough"
  fi
fi

if [[ "${START_AFTER}" == "yes" ]]; then
  msg_info "Starting CT ${CTID}"
  pct start "${CTID}"
fi

msg_ok "Container ${CTID} created"
msg_info "Check config: ${CONF}"
msg_info "Open shell: pct enter ${CTID}"
