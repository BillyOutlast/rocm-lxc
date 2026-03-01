#!/usr/bin/env bash
set -euo pipefail

msg_info() { printf "[INFO] %s\n" "$1"; }
msg_ok() { printf "[OK] %s\n" "$1"; }
msg_error() { printf "[ERROR] %s\n" "$1"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    msg_error "Missing required command: $1"
    exit 1
  }
}

if [[ "${EUID}" -ne 0 ]]; then
  msg_error "Run this script as root on a Proxmox host"
  exit 1
fi

require_cmd pct

CTID="${1:-}"
if [[ -z "${CTID}" ]]; then
  read -r -p "Container ID to update: " CTID
fi

if ! pct status "${CTID}" >/dev/null 2>&1; then
  msg_error "CT ${CTID} does not exist"
  exit 1
fi

WAS_RUNNING="no"
if pct status "${CTID}" | grep -q "running"; then
  WAS_RUNNING="yes"
else
  msg_info "Starting CT ${CTID}"
  pct start "${CTID}"
fi

msg_info "Updating packages in CT ${CTID}"
pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get -y full-upgrade; apt-get -y autoremove; apt-get autoclean'

if [[ "${WAS_RUNNING}" == "no" ]]; then
  msg_info "Stopping CT ${CTID} (it was originally stopped)"
  pct shutdown "${CTID}" --timeout 60 || pct stop "${CTID}"
fi

msg_ok "Update completed for CT ${CTID}"
