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
require_cmd pvesm
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

CT_WAS_STARTED_FOR_APPS="no"
if [[ "${INSTALL_OLLAMA}" == "yes" || "${INSTALL_VLLM}" == "yes" || "${INSTALL_LLAMA_CPP}" == "yes" || "${INSTALL_OPEN_WEBUI}" == "yes" || "${INSTALL_COMFYUI}" == "yes" ]]; then
  if ! pct status "${CTID}" | grep -q "running"; then
    msg_info "Starting CT ${CTID} for optional AI component installation"
    pct start "${CTID}"
    CT_WAS_STARTED_FOR_APPS="yes"
  fi

  msg_info "Preparing container package baseline"
  pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get -y install curl ca-certificates gnupg lsb-release software-properties-common'

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
    pct exec "${CTID}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -y install python3 python3-venv python3-pip git; id -u openwebui >/dev/null 2>&1 || useradd -r -m -d /opt/open-webui -s /usr/sbin/nologin openwebui; mkdir -p /opt/open-webui /var/lib/open-webui; chown -R openwebui:openwebui /opt/open-webui /var/lib/open-webui; python3 -m venv /opt/open-webui/.venv; /opt/open-webui/.venv/bin/pip install --upgrade pip setuptools wheel; /opt/open-webui/.venv/bin/pip install --upgrade git+https://github.com/open-webui/open-webui.git'
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
