#!/usr/bin/env bash
set -euo pipefail

JSON_MODE=0
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
CHECKS_JSON=""
DGPU_READY="no"
IGPU_READY="no"
HYBRID_READY="no"

usage() {
  cat <<'EOF'
Usage: proxmox-ai-readiness-check.sh [--json]

Options:
  --json    Emit machine-readable JSON output
  -h        Show this help
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --json)
      JSON_MODE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf "%s" "${value}"
}

append_check() {
  local status="$1"
  local message="$2"
  local escaped_message
  escaped_message="$(json_escape "${message}")"
  local entry
  entry="{\"status\":\"${status}\",\"message\":\"${escaped_message}\"}"
  if [[ -z "${CHECKS_JSON}" ]]; then
    CHECKS_JSON="${entry}"
  else
    CHECKS_JSON="${CHECKS_JSON},${entry}"
  fi
}

msg_info() { printf "[INFO] %s\n" "$1"; }
msg_ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  append_check "pass" "$1"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf "[PASS] %s\n" "$1"
  fi
}
msg_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  append_check "warn" "$1"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf "[WARN] %s\n" "$1"
  fi
}
msg_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  append_check "fail" "$1"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf "[FAIL] %s\n" "$1"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

if [[ "${EUID}" -ne 0 ]]; then
  msg_fail "Run this script as root on a Proxmox host"
  if [[ "${JSON_MODE}" -eq 1 ]]; then
    printf '{"summary":{"pass":%d,"warn":%d,"fail":%d},"profiles":{"dgpu":"%s","igpu":"%s","hybrid":"%s"},"checks":[%s]}\n' \
      "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}" "${DGPU_READY}" "${IGPU_READY}" "${HYBRID_READY}" "${CHECKS_JSON}"
  fi
  exit 1
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  msg_info "Proxmox AI readiness audit (AMD dGPU/iGPU/hybrid)"
  echo
fi

if command_exists pveversion; then
  PVE_VERSION="$(pveversion | head -n1)"
  msg_ok "Detected Proxmox: ${PVE_VERSION}"
else
  msg_fail "pveversion command not found (this does not look like a Proxmox host)"
fi

for cmd in lspci dmesg grep awk sed; do
  if command_exists "${cmd}"; then
    msg_ok "Required command present: ${cmd}"
  else
    msg_fail "Missing required command: ${cmd}"
  fi
done

if [[ "${JSON_MODE}" -eq 0 ]]; then
  echo
  msg_info "Checking virtualization and IOMMU baseline"
fi

CPU_FLAGS="$(grep -m1 '^flags' /proc/cpuinfo || true)"
if echo "${CPU_FLAGS}" | grep -qw 'svm'; then
  msg_ok "AMD SVM CPU flag present"
else
  msg_warn "AMD SVM CPU flag not detected in /proc/cpuinfo"
fi

GRUB_FILE="/etc/default/grub"
GRUB_LINE="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${GRUB_FILE}" 2>/dev/null || true)"
if echo "${GRUB_LINE}" | grep -q 'amd_iommu=on'; then
  msg_ok "GRUB contains amd_iommu=on"
else
  msg_warn "GRUB missing amd_iommu=on (recommended for passthrough)"
fi

if echo "${GRUB_LINE}" | grep -q 'iommu=pt'; then
  msg_ok "GRUB contains iommu=pt"
else
  msg_warn "GRUB missing iommu=pt (recommended for lower IOMMU overhead)"
fi

if dmesg | grep -Eiq 'AMD-Vi|IOMMU enabled|IOMMU.*enabled'; then
  msg_ok "Kernel reports IOMMU enabled"
else
  msg_fail "IOMMU does not appear enabled in kernel logs"
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  echo
  msg_info "Detecting GPU devices"
fi

GPU_LINES="$(lspci -nn | grep -Ei 'VGA|Display|3D' || true)"
if [[ -z "${GPU_LINES}" ]]; then
  msg_fail "No VGA/Display/3D controllers found"
else
  msg_ok "Detected display controllers"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf "%s\n" "${GPU_LINES}" | sed 's/^/  - /'
  fi
fi

AMD_GPU_LINES="$(printf "%s\n" "${GPU_LINES}" | grep -Ei 'AMD|ATI|Advanced Micro Devices' || true)"
AMD_GPU_COUNT="$(printf "%s\n" "${AMD_GPU_LINES}" | sed '/^$/d' | wc -l | awk '{print $1}')"

if [[ "${AMD_GPU_COUNT}" -ge 1 ]]; then
  msg_ok "AMD GPU controller(s) detected: ${AMD_GPU_COUNT}"
else
  msg_warn "No AMD GPU controllers detected"
fi

AMD_AUDIO_FUNCS="$(lspci -nn | grep -Ei 'Audio device:.*AMD|ATI|Advanced Micro Devices' || true)"
if [[ -n "${AMD_AUDIO_FUNCS}" ]]; then
  msg_ok "Detected AMD GPU audio function(s) (useful for full dGPU passthrough)"
else
  msg_warn "No AMD GPU audio functions detected"
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  echo
  msg_info "Checking GPU device nodes for shared LXC workflows"
fi

if [[ -d /dev/dri ]]; then
  msg_ok "/dev/dri exists"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    ls -l /dev/dri | sed 's/^/  /'
  fi
else
  msg_warn "/dev/dri missing"
fi

if [[ -e /dev/kfd ]]; then
  msg_ok "/dev/kfd exists"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    ls -l /dev/kfd | sed 's/^/  /'
  fi
else
  msg_warn "/dev/kfd missing (ROCm compute in LXC may not work)"
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  echo
  msg_info "Checking host performance baseline"
fi

TOTAL_MEM_GB="$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)"
if [[ "${JSON_MODE}" -eq 0 ]]; then
  msg_info "Host RAM total: ${TOTAL_MEM_GB} GiB"
fi

if awk "BEGIN{exit !(${TOTAL_MEM_GB} >= 32.0)}"; then
  msg_ok "Host RAM >= 32 GiB"
else
  msg_warn "Host RAM < 32 GiB (tight for larger AI models)"
fi

if [[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  if [[ "${GOV}" == "performance" ]]; then
    msg_ok "CPU governor is performance"
  else
    msg_warn "CPU governor is ${GOV} (performance recommended during benchmarking)"
  fi
else
  msg_warn "CPU governor interface not found"
fi

ROOT_FS_TYPE="$(findmnt -n -o FSTYPE / || true)"
if [[ "${JSON_MODE}" -eq 0 ]]; then
  msg_info "Root filesystem type: ${ROOT_FS_TYPE:-unknown}"
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  echo
  msg_info "Readiness summary by machine profile"
fi

if [[ "${AMD_GPU_COUNT}" -ge 1 ]] && dmesg | grep -Eiq 'AMD-Vi|IOMMU enabled|IOMMU.*enabled'; then
  DGPU_READY="yes"
fi

if [[ -d /dev/dri ]] && [[ -e /dev/kfd ]]; then
  IGPU_READY="yes"
fi

if [[ "${AMD_GPU_COUNT}" -ge 2 ]] && [[ -d /dev/dri ]]; then
  HYBRID_READY="yes"
fi

if [[ "${DGPU_READY}" == "yes" ]]; then
  msg_ok "dGPU machine baseline: READY"
else
  msg_warn "dGPU machine baseline: PARTIAL (check IOMMU/GPU detection)"
fi

if [[ "${IGPU_READY}" == "yes" ]]; then
  msg_ok "iGPU/APU machine baseline: READY"
else
  msg_warn "iGPU/APU machine baseline: PARTIAL (check /dev/dri and /dev/kfd)"
fi

if [[ "${HYBRID_READY}" == "yes" ]]; then
  msg_ok "Hybrid (iGPU + dGPU) baseline: READY"
else
  msg_warn "Hybrid baseline: PARTIAL (typically needs 2 detected GPU controllers)"
fi

if [[ "${JSON_MODE}" -eq 0 ]]; then
  echo
  msg_info "Recommended next steps"
  cat <<'EOF'
- For dGPU passthrough VMs: set VM CPU type to host, machine q35, OVMF, add all GPU PCI functions.
- For LXC shared GPU: map /dev/dri and /dev/kfd plus cgroup2 allow rules in /etc/pve/lxc/<CTID>.conf.
- Keep heavy model data on NVMe and avoid memory overcommit for latency-sensitive inference.
- Use docs/PROXMOX-AI-WORKLOAD-GUIDE.md for full tuning patterns.
EOF
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  printf '{"summary":{"pass":%d,"warn":%d,"fail":%d},"profiles":{"dgpu":"%s","igpu":"%s","hybrid":"%s"},"checks":[%s]}\n' \
    "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}" "${DGPU_READY}" "${IGPU_READY}" "${HYBRID_READY}" "${CHECKS_JSON}"
else
  echo
  printf "Result: PASS=%d WARN=%d FAIL=%d\n" "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
fi

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 2
fi

exit 0
