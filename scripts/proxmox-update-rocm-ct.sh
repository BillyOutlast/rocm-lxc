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

ensure_ct_dns() {
  local ctid="$1"
  if ct_dns_ok "${ctid}"; then
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
configure_ct_apt_network "${CTID}"
ensure_ct_dns "${CTID}"
ct_apt_update_retry "${CTID}"
pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install zstd curl ca-certificates; apt-get -y full-upgrade; apt-get -y autoremove; apt-get autoclean'

if prompt_yes_no "Update Ollama in CT ${CTID}" "no"; then
  msg_info "Updating Ollama"
  pct exec "${CTID}" -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'
  pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl restart ollama; systemctl enable ollama'
  msg_ok "Ollama updated"
fi

if prompt_yes_no "Update vLLM in CT ${CTID}" "no"; then
  msg_info "Updating vLLM"
  pct exec "${CTID}" -- bash -lc 'if [[ -x /opt/vllm/.venv/bin/pip ]]; then /opt/vllm/.venv/bin/pip install --upgrade pip setuptools wheel vllm; else export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip; mkdir -p /opt/vllm; python3 -m venv /opt/vllm/.venv; /opt/vllm/.venv/bin/pip install --upgrade pip setuptools wheel vllm; fi'
  if pct exec "${CTID}" -- bash -lc 'systemctl list-unit-files | grep -q "^vllm.service"'; then
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl restart vllm; systemctl enable vllm'
    msg_ok "vLLM updated and service restarted"
  else
    msg_warn "vLLM updated but vllm.service not found"
  fi
fi

if prompt_yes_no "Update llama.cpp in CT ${CTID}" "no"; then
  msg_info "Updating llama.cpp"
  pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install git build-essential cmake pkg-config hipcc rocminfo; if [[ -d /opt/llama.cpp/.git ]]; then git -C /opt/llama.cpp pull --ff-only; else git clone https://github.com/ggml-org/llama.cpp /opt/llama.cpp; fi; cmake -S /opt/llama.cpp -B /opt/llama.cpp/build -DGGML_HIP=ON -DCMAKE_BUILD_TYPE=Release; cmake --build /opt/llama.cpp/build -j"$(nproc)"'
  if pct exec "${CTID}" -- bash -lc 'systemctl list-unit-files | grep -q "^llama-cpp.service"'; then
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl restart llama-cpp; systemctl enable llama-cpp'
    msg_ok "llama.cpp updated and service restarted"
  else
    msg_warn "llama.cpp updated but llama-cpp.service not found"
  fi
fi

if prompt_yes_no "Update Open WebUI in CT ${CTID}" "no"; then
  msg_info "Updating Open WebUI"
  pct exec "${CTID}" -- bash -lc 'if [[ -x /opt/open-webui/.venv/bin/pip ]]; then /opt/open-webui/.venv/bin/pip install --upgrade git+https://github.com/open-webui/open-webui.git; else export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip git; id -u openwebui >/dev/null 2>&1 || useradd -r -m -d /opt/open-webui -s /usr/sbin/nologin openwebui; mkdir -p /opt/open-webui /var/lib/open-webui; chown -R openwebui:openwebui /opt/open-webui /var/lib/open-webui; python3 -m venv /opt/open-webui/.venv; /opt/open-webui/.venv/bin/pip install --upgrade pip setuptools wheel; /opt/open-webui/.venv/bin/pip install --upgrade git+https://github.com/open-webui/open-webui.git; fi'
  if pct exec "${CTID}" -- bash -lc 'systemctl list-unit-files | grep -q "^open-webui.service"'; then
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl restart open-webui; systemctl enable open-webui'
    msg_ok "Open WebUI updated and service restarted"
  else
    msg_warn "Open WebUI updated but open-webui.service not found"
  fi
fi

if prompt_yes_no "Update ComfyUI in CT ${CTID}" "no"; then
  msg_info "Updating ComfyUI"
  pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip git; if [[ -d /opt/comfyui/.git ]]; then git -C /opt/comfyui pull --ff-only; else rm -rf /opt/comfyui; git clone https://github.com/Comfy-Org/ComfyUI /opt/comfyui; fi; if [[ ! -x /opt/comfyui/.venv/bin/pip ]]; then python3 -m venv /opt/comfyui/.venv; fi; /opt/comfyui/.venv/bin/pip install --upgrade pip setuptools wheel; /opt/comfyui/.venv/bin/pip install -r /opt/comfyui/requirements.txt; id -u comfyui >/dev/null 2>&1 || useradd -r -m -d /opt/comfyui -s /usr/sbin/nologin comfyui; chown -R comfyui:comfyui /opt/comfyui /var/lib/comfyui || true'

  if prompt_yes_no "Update ComfyUI-Manager in CT ${CTID}" "yes"; then
    msg_info "Updating ComfyUI-Manager"
    pct exec "${CTID}" -- bash -lc 'mkdir -p /opt/comfyui/custom_nodes; if [[ -d /opt/comfyui/custom_nodes/ComfyUI-Manager/.git ]]; then git -C /opt/comfyui/custom_nodes/ComfyUI-Manager pull --ff-only; else rm -rf /opt/comfyui/custom_nodes/ComfyUI-Manager; git clone https://github.com/Comfy-Org/ComfyUI-Manager /opt/comfyui/custom_nodes/ComfyUI-Manager; fi; if [[ -f /opt/comfyui/custom_nodes/ComfyUI-Manager/requirements.txt ]]; then /opt/comfyui/.venv/bin/pip install -r /opt/comfyui/custom_nodes/ComfyUI-Manager/requirements.txt; fi; chown -R comfyui:comfyui /opt/comfyui/custom_nodes/ComfyUI-Manager || true'
    msg_ok "ComfyUI-Manager updated"
  fi

  if pct exec "${CTID}" -- bash -lc 'systemctl list-unit-files | grep -q "^comfyui.service"'; then
    pct exec "${CTID}" -- bash -lc 'systemctl daemon-reload; systemctl restart comfyui; systemctl enable comfyui'
    msg_ok "ComfyUI updated and service restarted"
  else
    msg_warn "ComfyUI updated but comfyui.service not found"
  fi
fi

if [[ "${WAS_RUNNING}" == "no" ]]; then
  msg_info "Stopping CT ${CTID} (it was originally stopped)"
  pct shutdown "${CTID}" --timeout 60 || pct stop "${CTID}"
fi

msg_ok "Update completed for CT ${CTID}"
