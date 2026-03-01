# ROCm Docker -> Proxmox LXC Template

This repository builds a Proxmox-compatible LXC rootfs archive from:

- `rocm/dev-ubuntu-24.04:7.2-complete`

## What the GitHub Action does

The workflow:

1. Pulls the Docker image
2. Exports its merged filesystem with `docker export`
3. Packs the filesystem into `dist/<template_name>.tar.gz`
4. Publishes the archive and SHA256 checksum as GitHub Action artifacts

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

## Notes for ROCm in LXC

ROCm in LXC usually requires additional host and container configuration (device nodes, cgroup permissions, and matching kernel/driver stack). The template build only converts filesystem contents; it does not configure GPU passthrough automatically.

## Files

- `.github/workflows/build-rocm-lxc.yml` - GitHub Action
- `.github/workflows/release-rocm-lxc.yml` - auto-publish workflow to GitHub Releases
- `.github/workflows/release-rocm-lxc-latest.yml` - rolling latest release workflow
- `scripts/build-lxc-rootfs.sh` - conversion script
- `scripts/proxmox-install-rocm-ct.sh` - Proxmox CT install/config helper
- `scripts/proxmox-update-rocm-ct.sh` - Proxmox CT update helper
