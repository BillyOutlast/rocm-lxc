#!/usr/bin/env bash
set -euo pipefail

msg_info() { printf "[INFO] %s\n" "$1"; }
msg_ok() { printf "[OK] %s\n" "$1"; }
msg_warn() { printf "[WARN] %s\n" "$1"; }
msg_error() { printf "[ERROR] %s\n" "$1"; }

template_file_exists() {
  local template_volume="$1"
  local resolved_path
  resolved_path="$(pvesm path "${template_volume}" 2>/dev/null || true)"
  [[ -n "${resolved_path}" && -f "${resolved_path}" ]]
}

remove_gpu_passthrough_from_conf() {
  local conf_file="$1"
  sed -i -E '/^lxc\.cgroup2\.devices\.allow: c 226:\* rwm$/d' "${conf_file}"
  sed -i -E '/^lxc\.mount\.entry: \/dev\/dri dev\/dri none bind,optional,create=dir$/d' "${conf_file}"
  sed -i -E '/^lxc\.cgroup2\.devices\.allow: c 235:\* rwm$/d' "${conf_file}"
  sed -i -E '/^lxc\.mount\.entry: \/dev\/kfd dev\/kfd none bind,optional,create=file$/d' "${conf_file}"
}

start_ct_with_recovery() {
  local ctid="$1"
  local conf_file="$2"
  local gpu_enabled="$3"

  if pct start "${ctid}"; then
    return 0
  fi

  msg_warn "Container ${ctid} failed to start"

  if [[ "${gpu_enabled}" == "yes" ]]; then
    msg_warn "Retrying start without GPU passthrough entries"
    remove_gpu_passthrough_from_conf "${conf_file}"
    if pct start "${ctid}"; then
      msg_warn "Container ${ctid} started after disabling GPU passthrough"
      return 0
    fi
  fi

  msg_error "Container ${ctid} still failed to start"
  msg_info "Running pct start --debug for detailed diagnostics"
  pct start "${ctid}" --debug || true
  msg_info "Recent container service logs:"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "pve-container@${ctid}.service" -n 80 --no-pager || true
  else
    msg_warn "journalctl not found on host"
  fi
  msg_info "Container config: /etc/pve/lxc/${ctid}.conf"
  return 1
}

verify_ct_init_present() {
  local ctid="$1"
  local mount_output mount_dir

  mount_output="$(pct mount "${ctid}" 2>/dev/null || true)"
  mount_dir="$(printf '%s\n' "${mount_output}" | sed -n "s/.*'\(.*\)'.*/\1/p" | tail -n1)"

  if [[ -z "${mount_dir}" || ! -d "${mount_dir}" ]]; then
    msg_warn "Could not mount CT ${ctid} rootfs to validate init binary"
    return 0
  fi

  if [[ -x "${mount_dir}/sbin/init" || -x "${mount_dir}/lib/systemd/systemd" ]]; then
    msg_ok "CT rootfs preflight: init/systemd binary detected"
    pct unmount "${ctid}" >/dev/null 2>&1 || true
    return 0
  fi

  msg_error "CT rootfs preflight failed: no /sbin/init or /lib/systemd/systemd found"
  msg_error "This Docker-derived rootfs cannot boot as a standard Proxmox LXC without an init system"
  pct unmount "${ctid}" >/dev/null 2>&1 || true
  return 1
}

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

configure_ct_apt_network() {
  local ctid="$1"
  pct exec "${ctid}" -- bash -lc '
set -euo pipefail
cat > /etc/apt/apt.conf.d/99rocm-lxc-network <<EOF
Acquire::Retries "10";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::http::Pipeline-Depth "0";
EOF

if [[ -f /etc/apt/sources.list ]]; then
  sed -i "s|http://archive.ubuntu.com/ubuntu|http://mirrors.edge.kernel.org/ubuntu|g" /etc/apt/sources.list
  sed -i "s|https://archive.ubuntu.com/ubuntu|http://mirrors.edge.kernel.org/ubuntu|g" /etc/apt/sources.list
fi

if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  sed -i "s|http://archive.ubuntu.com/ubuntu|http://mirrors.edge.kernel.org/ubuntu|g" /etc/apt/sources.list.d/ubuntu.sources
  sed -i "s|https://archive.ubuntu.com/ubuntu|http://mirrors.edge.kernel.org/ubuntu|g" /etc/apt/sources.list.d/ubuntu.sources
fi
'
}

ct_dns_ok() {
  local ctid="$1"
  pct exec "${ctid}" -- bash -lc 'getent hosts archive.ubuntu.com >/dev/null 2>&1 || getent hosts security.ubuntu.com >/dev/null 2>&1 || getent hosts repo.radeon.com >/dev/null 2>&1'
}

bootstrap_ct_networking() {
  local ctid="$1"
  pct exec "${ctid}" -- bash -lc '
set -euo pipefail

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-eth0-dhcp.network <<EOF
[Match]
Name=eth0

[Network]
DHCP=yes
DNS=1.1.1.1
DNS=8.8.8.8
EOF

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable systemd-networkd >/dev/null 2>&1 || true
  systemctl restart systemd-networkd >/dev/null 2>&1 || true

  systemctl enable systemd-resolved >/dev/null 2>&1 || true
  systemctl restart systemd-resolved >/dev/null 2>&1 || true

  if [[ -e /run/systemd/resolve/resolv.conf ]]; then
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
  elif [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true
  fi
fi
'
}

repair_ct_dns() {
  local ctid="$1"
  pct exec "${ctid}" -- bash -lc '
set -euo pipefail
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3 rotate
EOF
'
}

print_ct_network_diagnostics() {
  local ctid="$1"
  msg_info "CT ${ctid} network diagnostics:"
  pct exec "${ctid}" -- bash -lc 'set +e; ip -br addr; echo; ip route; echo; cat /etc/resolv.conf' || true
}

ensure_ct_dns() {
  local ctid="$1"
  if ct_dns_ok "${ctid}"; then
    return 0
  fi

  msg_warn "DNS resolution failed in CT ${ctid}; attempting network bootstrap"
  bootstrap_ct_networking "${ctid}"
  sleep 2

  if ct_dns_ok "${ctid}"; then
    msg_ok "DNS resolution recovered in CT ${ctid} after network bootstrap"
    return 0
  fi

  msg_warn "DNS resolution failed in CT ${ctid}; attempting /etc/resolv.conf repair"
  repair_ct_dns "${ctid}"
  sleep 1

  if ct_dns_ok "${ctid}"; then
    msg_ok "DNS resolution recovered in CT ${ctid}"
    return 0
  fi

  msg_error "DNS is still failing inside CT ${ctid}"
  print_ct_network_diagnostics "${ctid}"
  msg_error "Check CT network config, bridge, gateway, and host DNS forwarding"
  return 1
}

ct_apt_update_retry() {
  local ctid="$1"
  pct exec "${ctid}" -- bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
for attempt in 1 2 3 4 5; do
  if apt-get -o Acquire::Retries=10 -o Acquire::ForceIPv4=true update; then
    exit 0
  fi
  sleep $((attempt * 2))
done
echo "apt-get update failed after retries" >&2
exit 1
'
}

download_template_from_release() {
  local template_volume="$1"
  local repo="${GITHUB_REPO:-BillyOutlast/rocm-lxc}"
  local tag="${RELEASE_TAG:-lxc-template-latest}"

  if [[ "${template_volume}" != *:vztmpl/* ]]; then
    msg_warn "Template volume format is not storage:vztmpl/file.tar.gz; skipping auto-download"
    return 1
  fi

  local storage="${template_volume%%:*}"
  local template_name="${template_volume#*:vztmpl/}"

  if [[ "${storage}" != "local" ]]; then
    msg_warn "Auto-download currently supports only local:vztmpl storage"
    msg_warn "Selected storage: ${storage}"
    return 1
  fi

  local cache_dir="/var/lib/vz/template/cache"
  local destination="${cache_dir}/${template_name}"
  mkdir -p "${cache_dir}"

  if [[ -f "${destination}" ]]; then
    msg_ok "Template already present: ${destination}"
    return 0
  fi

  local api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  local auth_header=()
  if [[ -n "${GH_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: Bearer ${GH_TOKEN}")
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  msg_info "Querying release ${tag} from ${repo}"
  local release_json
  release_json="$(curl -fsSL -H "Accept: application/vnd.github+json" "${auth_header[@]}" "${api_url}")"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  printf "%s" "${release_json}" > "${tmp_dir}/release.json"

  local exact_url
  local exact_sha_url
  local parts_sha_url
  mapfile -t part_urls < <(python3 - "${template_name}" "${tmp_dir}/release.json" <<'PY'
import json, re, sys

template = sys.argv[1]
release_file = sys.argv[2]
with open(release_file, "r", encoding="utf-8") as f:
    data = json.load(f)

assets = data.get("assets", [])
asset_map = {a.get("name", ""): a.get("browser_download_url", "") for a in assets}

exact_url = asset_map.get(template, "")
exact_sha = asset_map.get(f"{template}.sha256", "")
parts_sha = asset_map.get(f"{template}.parts.sha256", "")

if exact_url:
    print(f"EXACT_URL\t{exact_url}")
if exact_sha:
    print(f"EXACT_SHA_URL\t{exact_sha}")
if parts_sha:
    print(f"PARTS_SHA_URL\t{parts_sha}")

part_pattern = re.compile(rf"^{re.escape(template)}\.\d{{3}}\.part$")
for name in sorted(asset_map):
    if part_pattern.match(name):
        print(f"PART_URL\t{asset_map[name]}")
PY
)

local part_url_list=()
local line key value
for line in "${part_urls[@]}"; do
  key="${line%%$'\t'*}"
  value="${line#*$'\t'}"
  case "${key}" in
    EXACT_URL) exact_url="${value}" ;;
    EXACT_SHA_URL) exact_sha_url="${value}" ;;
    PARTS_SHA_URL) parts_sha_url="${value}" ;;
    PART_URL) part_url_list+=("${value}") ;;
  esac
done

if [[ -n "${exact_url:-}" ]]; then
  msg_info "Downloading template asset ${template_name}"
  curl -fL "${auth_header[@]}" "${exact_url}" -o "${destination}"
  if [[ -n "${exact_sha_url:-}" ]]; then
    curl -fL "${auth_header[@]}" "${exact_sha_url}" -o "${destination}.sha256"
    (cd "${cache_dir}" && sha256sum -c "$(basename "${destination}.sha256")")
  fi
  msg_ok "Downloaded template: ${destination}"
  return 0
fi

if [[ "${#part_url_list[@]}" -gt 0 ]]; then
  msg_info "Downloading ${#part_url_list[@]} split parts for ${template_name}"
  local part_url part_file
  for part_url in "${part_url_list[@]}"; do
    part_file="${tmp_dir}/$(basename "${part_url}")"
    curl -fL "${auth_header[@]}" "${part_url}" -o "${part_file}"
  done

  if [[ -n "${parts_sha_url:-}" ]]; then
    curl -fL "${auth_header[@]}" "${parts_sha_url}" -o "${tmp_dir}/${template_name}.parts.sha256"
    (cd "${tmp_dir}" && sha256sum -c "${template_name}.parts.sha256")
  fi

  cat "${tmp_dir}/${template_name}".*.part > "${destination}"
  sha256sum "${destination}" > "${destination}.sha256"
  msg_ok "Downloaded and reassembled template: ${destination}"
  return 0
fi

msg_error "Template asset not found in ${repo} release tag ${tag}"
return 1
}

if [[ "${EUID}" -ne 0 ]]; then
  msg_error "Run this script as root on a Proxmox host"
  exit 1
fi

require_cmd pct
require_cmd pvesh
require_cmd pvesm
require_cmd awk
require_cmd sed
require_cmd curl
require_cmd python3

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

if prompt_yes_no "Install Ollama in container" "no"; then
  INSTALL_OLLAMA="yes"
else
  INSTALL_OLLAMA="no"
fi

if prompt_yes_no "Install vLLM in container" "no"; then
  INSTALL_VLLM="yes"
  VLLM_MODEL="$(prompt_default "vLLM model id" "Qwen/Qwen2.5-7B-Instruct")"
  VLLM_HOST="$(prompt_default "vLLM bind host" "0.0.0.0")"
  VLLM_PORT="$(prompt_default "vLLM port" "8000")"
else
  INSTALL_VLLM="no"
  VLLM_MODEL=""
  VLLM_HOST=""
  VLLM_PORT=""
fi

if prompt_yes_no "Install llama.cpp in container" "no"; then
  INSTALL_LLAMA_CPP="yes"
  LLAMA_CPP_MODEL_PATH="$(prompt_default "llama.cpp model path" "/opt/models/model.gguf")"
  LLAMA_CPP_HOST="$(prompt_default "llama.cpp bind host" "0.0.0.0")"
  LLAMA_CPP_PORT="$(prompt_default "llama.cpp port" "8080")"
else
  INSTALL_LLAMA_CPP="no"
  LLAMA_CPP_MODEL_PATH=""
  LLAMA_CPP_HOST=""
  LLAMA_CPP_PORT=""
fi

if prompt_yes_no "Install Open WebUI in container" "no"; then
  INSTALL_OPEN_WEBUI="yes"
  OPEN_WEBUI_HOST="$(prompt_default "Open WebUI bind host" "0.0.0.0")"
  OPEN_WEBUI_PORT="$(prompt_default "Open WebUI port" "3000")"
else
  INSTALL_OPEN_WEBUI="no"
  OPEN_WEBUI_HOST=""
  OPEN_WEBUI_PORT=""
fi

if prompt_yes_no "Install ComfyUI in container" "no"; then
  INSTALL_COMFYUI="yes"
  COMFYUI_HOST="$(prompt_default "ComfyUI bind host" "0.0.0.0")"
  COMFYUI_PORT="$(prompt_default "ComfyUI port" "8188")"
  if prompt_yes_no "Install ComfyUI-Manager plugin" "yes"; then
    INSTALL_COMFYUI_MANAGER="yes"
  else
    INSTALL_COMFYUI_MANAGER="no"
  fi
else
  INSTALL_COMFYUI="no"
  INSTALL_COMFYUI_MANAGER="no"
  COMFYUI_HOST=""
  COMFYUI_PORT=""
fi

if pct status "${CTID}" >/dev/null 2>&1; then
  msg_error "CT ${CTID} already exists"
  exit 1
fi

if ! template_file_exists "${TEMPLATE}"; then
  msg_warn "Template not found in storage: ${TEMPLATE}"
  if prompt_yes_no "Download template from GitHub Release automatically" "yes"; then
    if ! download_template_from_release "${TEMPLATE}"; then
      msg_error "Automatic template download failed"
      exit 1
    fi
  else
    msg_info "Copy your template tarball into a storage CT template cache first"
    exit 1
  fi

  if ! template_file_exists "${TEMPLATE}"; then
    msg_error "Template still not found after download: ${TEMPLATE}"
    exit 1
  fi
fi

TEMPLATE_PATH="$(pvesm path "${TEMPLATE}" 2>/dev/null || true)"
if [[ -n "${TEMPLATE_PATH}" ]]; then
  if [[ -f "${TEMPLATE_PATH}" ]]; then
    msg_info "Template preflight: FOUND at ${TEMPLATE_PATH}"
  else
    msg_warn "Template preflight: RESOLVED path but file missing at ${TEMPLATE_PATH}"
  fi
else
  msg_warn "Template preflight: unable to resolve path for ${TEMPLATE}"
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"

if [[ -z "${TEMPLATE_PATH}" || ! -f "${TEMPLATE_PATH}" ]]; then
  msg_error "Refusing to create CT: template file is missing for ${TEMPLATE}"
  msg_error "Resolved path: ${TEMPLATE_PATH:-<unresolved>}"
  exit 1
fi

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

if ! verify_ct_init_present "${CTID}"; then
  exit 1
fi

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
  if ! start_ct_with_recovery "${CTID}" "${CONF}" "${ENABLE_GPU}"; then
    exit 1
  fi
fi

CT_WAS_STARTED_FOR_APPS="no"
if [[ "${INSTALL_OLLAMA}" == "yes" || "${INSTALL_VLLM}" == "yes" || "${INSTALL_LLAMA_CPP}" == "yes" || "${INSTALL_OPEN_WEBUI}" == "yes" || "${INSTALL_COMFYUI}" == "yes" ]]; then
  if ! pct status "${CTID}" | grep -q "running"; then
    msg_info "Starting CT ${CTID} for optional AI component installation"
    if ! start_ct_with_recovery "${CTID}" "${CONF}" "${ENABLE_GPU}"; then
      exit 1
    fi
    CT_WAS_STARTED_FOR_APPS="yes"
  fi

  msg_info "Preparing container package baseline"
  configure_ct_apt_network "${CTID}"
  ensure_ct_dns "${CTID}"
  ct_apt_update_retry "${CTID}"
  pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install zstd curl ca-certificates gnupg lsb-release software-properties-common'

  if [[ "${INSTALL_OLLAMA}" == "yes" ]]; then
    msg_info "Installing Ollama in CT ${CTID}"
    pct exec "${CTID}" -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl enable --now ollama'
    msg_ok "Ollama installed and enabled"
  fi

  if [[ "${INSTALL_VLLM}" == "yes" ]]; then
    msg_info "Installing vLLM in CT ${CTID}"
    pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip build-essential; id -u vllm >/dev/null 2>&1 || useradd -r -m -d /opt/vllm -s /usr/sbin/nologin vllm; mkdir -p /opt/vllm; python3 -m venv /opt/vllm/.venv; /opt/vllm/.venv/bin/pip install --upgrade pip setuptools wheel; /opt/vllm/.venv/bin/pip install --upgrade vllm'
    pct exec "${CTID}" -- bash -lc "cat > /etc/systemd/system/vllm.service <<EOF
[Unit]
Description=vLLM OpenAI-Compatible API Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vllm
Environment=PATH=/opt/vllm/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/vllm/.venv/bin/vllm serve ${VLLM_MODEL} --host ${VLLM_HOST} --port ${VLLM_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl enable --now vllm'
    msg_ok "vLLM installed and enabled"
  fi

  if [[ "${INSTALL_LLAMA_CPP}" == "yes" ]]; then
    msg_info "Installing llama.cpp in CT ${CTID}"
    pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install git build-essential cmake pkg-config hipcc rocminfo; if [[ -d /opt/llama.cpp/.git ]]; then git -C /opt/llama.cpp pull --ff-only; else git clone https://github.com/ggml-org/llama.cpp /opt/llama.cpp; fi; cmake -S /opt/llama.cpp -B /opt/llama.cpp/build -DGGML_HIP=ON -DCMAKE_BUILD_TYPE=Release; cmake --build /opt/llama.cpp/build -j"$(nproc)"; mkdir -p /opt/models'
    pct exec "${CTID}" -- bash -lc "cat > /etc/systemd/system/llama-cpp.service <<EOF
[Unit]
Description=llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp
ExecStart=/opt/llama.cpp/build/bin/llama-server -m ${LLAMA_CPP_MODEL_PATH} --host ${LLAMA_CPP_HOST} --port ${LLAMA_CPP_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl enable llama-cpp'
    if pct exec "${CTID}" -- bash -lc "test -f '${LLAMA_CPP_MODEL_PATH}'"; then
      pct exec "${CTID}" -- bash -lc 'systemctl restart llama-cpp'
      msg_ok "llama.cpp installed and enabled"
    else
      msg_warn "llama.cpp installed and enabled, but model file is missing; service start skipped"
      msg_info "Place model at ${LLAMA_CPP_MODEL_PATH} then run: pct exec ${CTID} -- systemctl start llama-cpp"
    fi
  fi

  if [[ "${INSTALL_OPEN_WEBUI}" == "yes" ]]; then
    OPENAI_BASE_URLS=""
    PRIMARY_OPENAI_BASE_URL=""

    if [[ "${INSTALL_VLLM}" == "yes" ]]; then
      OPENAI_BASE_URLS="http://127.0.0.1:${VLLM_PORT}/v1"
      PRIMARY_OPENAI_BASE_URL="${OPENAI_BASE_URLS}"
    fi

    if [[ "${INSTALL_LLAMA_CPP}" == "yes" ]]; then
      LLAMA_OPENAI_URL="http://127.0.0.1:${LLAMA_CPP_PORT}/v1"
      if [[ -n "${OPENAI_BASE_URLS}" ]]; then
        OPENAI_BASE_URLS="${OPENAI_BASE_URLS},${LLAMA_OPENAI_URL}"
      else
        OPENAI_BASE_URLS="${LLAMA_OPENAI_URL}"
        PRIMARY_OPENAI_BASE_URL="${LLAMA_OPENAI_URL}"
      fi
    fi

    if [[ -z "${PRIMARY_OPENAI_BASE_URL}" && -n "${OPENAI_BASE_URLS}" ]]; then
      PRIMARY_OPENAI_BASE_URL="${OPENAI_BASE_URLS%%,*}"
    fi

    if [[ "${INSTALL_OLLAMA}" != "yes" && -z "${OPENAI_BASE_URLS}" ]]; then
      msg_warn "Open WebUI selected, but no local backend was selected (Ollama/vLLM/llama.cpp)"
      msg_warn "Open WebUI will be installed; configure provider connections later in UI/env"
    fi

    msg_info "Installing Open WebUI in CT ${CTID}"
    pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip git; id -u openwebui >/dev/null 2>&1 || useradd -r -m -d /opt/open-webui -s /usr/sbin/nologin openwebui; mkdir -p /opt/open-webui /var/lib/open-webui; chown -R openwebui:openwebui /opt/open-webui /var/lib/open-webui; python3 -m venv /opt/open-webui/.venv; /opt/open-webui/.venv/bin/pip install --upgrade pip setuptools wheel; /opt/open-webui/.venv/bin/pip install --upgrade --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple torch; /opt/open-webui/.venv/bin/pip install --upgrade open-webui'
    pct exec "${CTID}" -- bash -lc "cat > /etc/systemd/system/open-webui.service <<EOF
[Unit]
Description=Open WebUI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openwebui
Group=openwebui
WorkingDirectory=/opt/open-webui
Environment=PATH=/opt/open-webui/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DATA_DIR=/var/lib/open-webui
Environment=OLLAMA_BASE_URL=http://127.0.0.1:11434
Environment=OPENAI_API_BASE_URL=${PRIMARY_OPENAI_BASE_URL}
Environment=OPENAI_API_BASE_URLS=${OPENAI_BASE_URLS}
ExecStart=/opt/open-webui/.venv/bin/open-webui serve --host ${OPEN_WEBUI_HOST} --port ${OPEN_WEBUI_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl enable --now open-webui'
    msg_ok "Open WebUI installed and enabled"
    msg_info "Open WebUI URL: http://${HOSTNAME}:${OPEN_WEBUI_PORT}"
  fi

  if [[ "${INSTALL_COMFYUI}" == "yes" ]]; then
    msg_info "Installing ComfyUI in CT ${CTID}"
    pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip git; id -u comfyui >/dev/null 2>&1 || useradd -r -m -d /opt/comfyui -s /usr/sbin/nologin comfyui; if [[ -d /opt/comfyui/.git ]]; then git -C /opt/comfyui pull --ff-only; else rm -rf /opt/comfyui; git clone https://github.com/Comfy-Org/ComfyUI /opt/comfyui; fi; mkdir -p /var/lib/comfyui; chown -R comfyui:comfyui /opt/comfyui /var/lib/comfyui; python3 -m venv /opt/comfyui/.venv; /opt/comfyui/.venv/bin/pip install --upgrade pip setuptools wheel; /opt/comfyui/.venv/bin/pip install -r /opt/comfyui/requirements.txt'

    if [[ "${INSTALL_COMFYUI_MANAGER}" == "yes" ]]; then
      msg_info "Installing ComfyUI-Manager plugin in CT ${CTID}"
      pct exec "${CTID}" -- bash -lc 'mkdir -p /opt/comfyui/custom_nodes; if [[ -d /opt/comfyui/custom_nodes/ComfyUI-Manager/.git ]]; then git -C /opt/comfyui/custom_nodes/ComfyUI-Manager pull --ff-only; else rm -rf /opt/comfyui/custom_nodes/ComfyUI-Manager; git clone https://github.com/Comfy-Org/ComfyUI-Manager /opt/comfyui/custom_nodes/ComfyUI-Manager; fi; if [[ -f /opt/comfyui/custom_nodes/ComfyUI-Manager/requirements.txt ]]; then /opt/comfyui/.venv/bin/pip install -r /opt/comfyui/custom_nodes/ComfyUI-Manager/requirements.txt; fi; chown -R comfyui:comfyui /opt/comfyui/custom_nodes/ComfyUI-Manager'
      msg_ok "ComfyUI-Manager installed"
    fi

    pct exec "${CTID}" -- bash -lc "cat > /etc/systemd/system/comfyui.service <<EOF
[Unit]
Description=ComfyUI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=comfyui
Group=comfyui
WorkingDirectory=/opt/comfyui
Environment=PATH=/opt/comfyui/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/comfyui/.venv/bin/python /opt/comfyui/main.py --listen ${COMFYUI_HOST} --port ${COMFYUI_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl enable --now comfyui'
    msg_ok "ComfyUI installed and enabled"
    msg_info "ComfyUI URL: http://${HOSTNAME}:${COMFYUI_PORT}"
  fi

  if [[ "${CT_WAS_STARTED_FOR_APPS}" == "yes" && "${START_AFTER}" != "yes" ]]; then
    msg_info "Stopping CT ${CTID} after optional AI component installation"
    pct shutdown "${CTID}" --timeout 60 || pct stop "${CTID}"
  fi
fi

msg_ok "Container ${CTID} created"
msg_info "Check config: ${CONF}"
msg_info "Open shell: pct enter ${CTID}"
