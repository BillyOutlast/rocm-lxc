# ROCm Docker -> Proxmox LXC Template

This repository builds a Proxmox-compatible LXC rootfs archive from:

- `rocm/dev-ubuntu-24.04:7.2-complete`

## What the GitHub Action does

The workflow:

1. Pulls the Docker image
2. Installs an init system (`systemd` by default) in the build container for LXC boot compatibility
3. Exports its merged filesystem with `docker export`
4. Packs the filesystem into `dist/<template_name>.tar.gz`
5. Publishes the archive and SHA256 checksum as GitHub Action artifacts

## Run the workflow

1. Push this repository to GitHub
2. Open **Actions** -> **Build ROCm LXC Template**
3. Click **Run workflow**
4. (Optional) override:
   - `image`
   - `template_name`
   - `retention_days`
5. Download the resulting artifact (`.tar.gz` + `.sha256`)

## Automatic GitHub Releases

After each successful **Build ROCm LXC Template** run, release workflows publish the same artifacts to GitHub Releases automatically.

- `Release ROCm LXC Template` creates immutable per-run tags (`lxc-template-<run_id>`)
- `Release ROCm LXC Template (Latest)` updates a moving stable tag (`lxc-template-latest`)
- Trigger: `workflow_run` on successful build workflow completion
- Assets uploaded: all generated `.tar.gz` and `.sha256` files

If a template archive exceeds GitHub Release per-asset limits, release workflows automatically split it into `.part` files plus a `.parts.sha256` checksum and reassembly note.

Reassemble on Linux:

```bash
cat rocm-dev-ubuntu-24.04-7.2-complete.tar.gz.*.part > rocm-dev-ubuntu-24.04-7.2-complete.tar.gz
```

Or use the helper script:

```bash
bash scripts/reassemble-template.sh rocm-dev-ubuntu-24.04-7.2-complete.tar.gz
```

Release tags are created per build run as `lxc-template-<run_id>`.
The stable rolling release is always available at tag `lxc-template-latest`.

## Import into Proxmox

### Option A: Place template in storage manually

On a Proxmox node (example uses `local` storage):

```bash
# Replace these values
TEMPLATE=rocm-dev-ubuntu-24.04-7.2-complete.tar.gz
STORAGE_PATH=/var/lib/vz/template/cache

cp "$TEMPLATE" "$STORAGE_PATH/"

# Verify Proxmox can see it
pveam available --section system
```

Then create a container from the template:

```bash
pct create 120 local:vztmpl/rocm-dev-ubuntu-24.04-7.2-complete.tar.gz \
  --hostname rocm-ct \
  --cores 8 \
  --memory 32768 \
  --swap 0 \
  --rootfs local-lvm:64 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1
```

### Option B: Upload through Proxmox UI

1. Datacenter -> Node -> `local` storage -> **CT Templates**
2. Upload the `.tar.gz`
3. Create CT and pick uploaded template

## Proxmox Helper Scripts

Two helper scripts are included under `scripts/`:

- `proxmox-install-rocm-ct.sh`: interactive CT creation + resource sizing + optional AMD GPU passthrough
- `proxmox-update-rocm-ct.sh`: run package updates inside an existing CT from the Proxmox host

### One-line install/update (community-scripts style)

You can run from GitHub raw URLs just like community-scripts:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BillyOutlast/rocm-lxc/main/ct/rocm-lxc.sh)"
```

Update helper in the same style (example CTID `120`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BillyOutlast/rocm-lxc/main/ct/rocm-lxc-update.sh)" - 120
```

### Community-scripts compatibility mode

Installer scripts now support a Community Scripts-style env/default model:

- `NONINTERACTIVE=yes` (or `PVE_NONINTERACTIVE=yes`) to skip prompts
- `var_cpu`, `var_ram`, `var_disk`, `var_unprivileged`, `var_gpu`
- direct overrides: `CTID`, `TEMPLATE`, `HOSTNAME`, `CORES`, `MEMORY`, `ROOTFS_SIZE`, etc.

Example:

```bash
NONINTERACTIVE=yes \
var_cpu=8 var_ram=32768 var_disk=80 var_unprivileged=1 var_gpu=yes \
CTID=120 HOSTNAME=rocm-ct-120 TEMPLATE=local:vztmpl/rocm-dev-ubuntu-24.04-7.2-complete.tar.gz \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BillyOutlast/rocm-lxc/main/ct/rocm-lxc.sh)"
```

Replace `BillyOutlast` with your GitHub account or org that hosts this repo.

If the selected template volume does not exist (for example `local:vztmpl/rocm-dev-ubuntu-24.04-7.2-complete.tar.gz`), installer scripts can now auto-download it from GitHub Releases (`lxc-template-latest`).

- Supports direct `.tar.gz` assets and split `.part` assets
- Reassembles split assets automatically into `/var/lib/vz/template/cache/`

Optional overrides:

- `GITHUB_REPO` (default: `BillyOutlast/rocm-lxc`)
- `RELEASE_TAG` (default: `lxc-template-latest`)

Run on the Proxmox host as `root`:

```bash
# 1) copy scripts to Proxmox host
scp scripts/proxmox-install-rocm-ct.sh root@pve-host:/root/
scp scripts/proxmox-update-rocm-ct.sh root@pve-host:/root/

# 2) execute install helper
ssh root@pve-host "bash /root/proxmox-install-rocm-ct.sh"

# 3) execute update helper later
ssh root@pve-host "bash /root/proxmox-update-rocm-ct.sh 120"
```

The install helper prompts for:

- CT ID
- template volume (`storage:vztmpl/template.tar.gz`)
- hostname
- CPU cores
- RAM (MB)
- swap (MB)
- rootfs storage + size
- bridge + IP config
- unprivileged mode
- start on completion
- AMD GPU passthrough (`/dev/dri`, `/dev/kfd`)
- optional install of `Ollama`
- optional install of `vLLM` (model id, host, port)
- optional install of `llama.cpp` (model path, host, port)
- optional install of `Open WebUI` (host, port)
- optional install of `ComfyUI` (host, port)
- optional install of `ComfyUI-Manager` plugin

When selected, these components are installed inside the CT and configured as systemd services:

- `ollama.service` (enabled + started)
- `vllm.service` (enabled + started)
- `llama-cpp.service` (enabled; started when model file exists)
- `open-webui.service` (enabled + started)
- `comfyui.service` (enabled + started)

When `Open WebUI` is selected, it is configured to use locally installed backends:

- `Ollama` via `OLLAMA_BASE_URL=http://127.0.0.1:11434`
- `vLLM` via `OPENAI_API_BASE_URL(S)=http://127.0.0.1:<vllm_port>/v1`
- `llama.cpp` via `OPENAI_API_BASE_URL(S)=http://127.0.0.1:<llama_cpp_port>/v1`

During update (`proxmox-update-rocm-ct.sh` or `ct/rocm-lxc-update.sh`), the script now asks whether to update each of:

- Ollama
- vLLM
- llama.cpp
- Open WebUI
- ComfyUI
- ComfyUI-Manager

Selected components are updated in the CT and their services are restarted when present.

If CT startup fails and GPU passthrough was enabled, installer scripts automatically retry once with `/dev/dri` and `/dev/kfd` passthrough entries removed, then print recent Proxmox container logs for troubleshooting.

Installer scripts also validate that CT rootfs contains an init binary (`/sbin/init` or `/lib/systemd/systemd`) before first start, and run `pct start --debug` diagnostics when startup still fails.

Installer and updater scripts now harden APT networking inside the CT (retries, force IPv4, timeouts, and Ubuntu mirror fallback from `archive.ubuntu.com` to `mirrors.edge.kernel.org`) to reduce repeated `Tried to start delayed item ... InRelease, but failed` warnings.

If DNS resolution fails inside the CT (`Could not resolve ...`), scripts now attempt automatic `/etc/resolv.conf` repair (Cloudflare + Google DNS) before package operations.

## Notes for ROCm in LXC

ROCm in LXC usually requires additional host and container configuration (device nodes, cgroup permissions, and matching kernel/driver stack). The template build only converts filesystem contents; it does not configure GPU passthrough automatically.

LXC containers use the **host kernel** (they do not ship their own kernel), but they still need a userspace init process (`/sbin/init` or systemd) to boot as a managed Proxmox CT. The build script now installs init packages by default so the converted Docker rootfs can start as an LXC container.

## Proxmox AI Optimization Guide

For full host and workload tuning guidance across dGPU, iGPU/APU, and hybrid machines, see:

- `docs/PROXMOX-AI-WORKLOAD-GUIDE.md`

## Proxmox AI Readiness Audit

Run an automated host readiness check for AMD dGPU, iGPU/APU, and hybrid setups.

Local script (on Proxmox host as `root`):

```bash
bash scripts/proxmox-ai-readiness-check.sh
```

Local JSON output (automation-friendly):

```bash
bash scripts/proxmox-ai-readiness-check.sh --json
```

Community-scripts style one-liner:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BillyOutlast/rocm-lxc/main/ct/rocm-lxc-audit.sh)"
```

Community-scripts style one-liner with JSON output:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BillyOutlast/rocm-lxc/main/ct/rocm-lxc-audit.sh)" - --json
```

Example parse with `jq`:

```bash
bash scripts/proxmox-ai-readiness-check.sh --json | jq '.summary, .profiles'
```

The audit checks:

- IOMMU and virtualization baseline
- GPU/controller detection
- `/dev/dri` and `/dev/kfd` readiness for LXC GPU sharing
- host RAM and CPU governor baseline
- profile readiness summary for dGPU, iGPU/APU, and hybrid machines

### GitHub Action (self-hosted Proxmox runner)

This repository also includes a workflow that runs the audit automatically on a self-hosted runner and uploads a JSON report artifact.

- Workflow: `Audit Proxmox AI Readiness`
- File: `.github/workflows/audit-proxmox-ai-readiness.yml`
- Triggers:
  - manual (`workflow_dispatch`)
  - weekly schedule (Sunday 04:00 UTC)

Runner requirements:

- self-hosted Linux runner installed on your Proxmox host (or equivalent host with Proxmox tools)
- ability to run the audit script as `root` (either runner user is root, or passwordless `sudo`)

Output artifact:

- `proxmox-ai-readiness-report.json`
- workflow job summary with pass/warn/fail counts, profile readiness, and failing checks

## Files

- `.github/workflows/build-rocm-lxc.yml` - GitHub Action
- `.github/workflows/audit-proxmox-ai-readiness.yml` - self-hosted Proxmox AI audit workflow
- `.github/workflows/release-rocm-lxc.yml` - auto-publish workflow to GitHub Releases
- `.github/workflows/release-rocm-lxc-latest.yml` - rolling latest release workflow
- `scripts/build-lxc-rootfs.sh` - conversion script
- `scripts/proxmox-install-rocm-ct.sh` - Proxmox CT install/config helper
- `scripts/proxmox-update-rocm-ct.sh` - Proxmox CT update helper
- `scripts/reassemble-template.sh` - rebuild split release template assets
- `ct/rocm-lxc.sh` - curl-friendly install entrypoint
- `ct/rocm-lxc-update.sh` - curl-friendly update entrypoint
- `ct/rocm-lxc-audit.sh` - curl-friendly Proxmox AI readiness audit
- `docs/PROXMOX-AI-WORKLOAD-GUIDE.md` - Proxmox AI tuning guide (dGPU/iGPU/hybrid)
- `scripts/proxmox-ai-readiness-check.sh` - local Proxmox AI readiness audit script
