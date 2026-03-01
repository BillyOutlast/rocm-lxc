# Proxmox AI Workload Optimization Guide

This guide focuses on Proxmox VE hosts running AI workloads with AMD GPUs in three common layouts:

- Dedicated dGPU machine (example: Radeon RX 7900 XTX)
- iGPU/APU machine (example: Ryzen AI Max+ 395 with Radeon 8060S)
- Hybrid machine using both iGPU and dGPU

It is written for practical homelab use with VMs and LXC containers.

## 1) Choose the right execution model

- Use **VM + full PCIe passthrough** for maximum isolation and most predictable GPU behavior.
- Use **LXC + `/dev/dri` + `/dev/kfd` mapping** for lower overhead and shared-host workflows.
- Prefer VM passthrough for training/inference jobs that need strict driver/runtime control.

## 2) Host-level baseline tuning (all hardware types)

## BIOS/UEFI settings

Enable these first:

- `SVM` / virtualization support
- `IOMMU`
- `Above 4G Decoding`
- `Resizable BAR` (if available)
- Power profile favoring performance (disable deep eco limits while benchmarking)

## Proxmox kernel and driver baseline

Edit `/etc/default/grub`:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```

Apply and reboot:

```bash
update-grub
reboot
```

After reboot, verify IOMMU:

```bash
dmesg | grep -E "IOMMU|AMD-Vi"
```

## CPU governor and scheduler baseline

Set performance governor (example one-shot):

```bash
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$cpu"
done
```

Recommended host policy:

- Keep host background services minimal.
- Pin latency-sensitive AI VMs to dedicated CPU sets.
- Reserve a few cores for Proxmox host tasks.

## Memory and storage baseline

- Use fast NVMe for model weights, cache, and datasets.
- For ZFS-backed VM disks, consider dataset tuning for mixed random IO:
  - `compression=lz4`
  - `atime=off`
- For large models, favor higher RAM and avoid host swap pressure.

## 3) dGPU machine optimization (RX 7900 XTX)

## Recommended architecture

- Best: dedicate 7900 XTX to one AI VM via VFIO passthrough.
- Alternative: share via LXC device mapping for multiple light workloads.

## A) Full passthrough to VM (best isolation)

Identify GPU devices:

```bash
lspci -nn | grep -E "VGA|Display|Audio"
```

Typical Radeon has at least:

- GPU function (display)
- HDMI/DP audio function

VM setup recommendations in Proxmox:

- Machine type: `q35`
- BIOS: `OVMF (UEFI)`
- CPU type: `host`
- Add all GPU functions via `hostpci`
- Enable `PCIe` and `ROM-Bar` as needed

Example VM config snippet (`/etc/pve/qemu-server/<VMID>.conf`):

```ini
machine: q35
bios: ovmf
cpu: host
hostpci0: 0000:03:00,pcie=1
hostpci1: 0000:03:00.1,pcie=1
```

Inside guest:

- Install current AMD ROCm stack supported by your distro/kernel.
- Validate with `rocminfo` and workload framework checks.

## B) LXC shared GPU mapping (lower overhead)

Add to container config (`/etc/pve/lxc/<CTID>.conf`):

```ini
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 235:* rwm
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

Also ensure container user/group permissions for render/video access.

## 4) iGPU/APU optimization (Ryzen AI Max+ 395 / Radeon 8060S)

## Key constraint

On many APU systems, the iGPU is also the host display adapter. Full passthrough can be difficult unless the host has another GPU for console output.

## Recommended approach

- Keep iGPU on host and expose `/dev/dri` (and `/dev/kfd` when present) to LXC or selected VMs.
- Use full passthrough only if host video can run on a different adapter.

## iGPU-focused best practices

- Increase shared memory headroom by provisioning generous system RAM.
- Avoid overcommitting memory across many AI containers.
- Pin CPU cores and memory limits per workload to prevent contention.
- Keep kernel and Mesa/ROCm userspace aligned to supported combinations.

## Ryzen AI/NPU note

NPU enablement on Linux evolves quickly. Treat NPU support separately from Radeon GPU setup, and validate with current kernel/driver documentation for your exact platform.

## 5) Hybrid machine optimization (iGPU + dGPU)

This is usually the best homelab AI layout.

Recommended split:

- Assign dGPU (7900 XTX) to a dedicated AI VM for heavy inference/training.
- Keep iGPU for host graphics, media tasks, light inference, or smaller LXC jobs.

Alternative split:

- Keep dGPU on host for shared LXC workloads.
- Use iGPU for low-priority services.

## Scheduling strategy

- Reserve CPU cores for host (for example 2–4 cores).
- Pin AI VM vCPUs to contiguous physical cores.
- Use NUMA-aware placement if available on your platform.
- Put datasets/checkpoints on the fastest local storage.

## 6) Proxmox resource profiles (starting points)

## Heavy AI VM profile (dGPU passthrough)

- vCPU: 8–16
- RAM: 32–96 GB
- Disk: NVMe-backed 200+ GB
- Ballooning: off for deterministic memory behavior

## Light/medium AI LXC profile (shared GPU)

- Cores: 4–8
- RAM: 16–32 GB
- Swap: 0–4096 MB (prefer low swap for latency-sensitive jobs)
- Features: `nesting=1,keyctl=1`

## 7) Validation checklist

On Proxmox host:

```bash
# GPU nodes visible
ls -l /dev/dri /dev/kfd

# IOMMU active
dmesg | grep -E "IOMMU|AMD-Vi"

# PCI topology
lspci -nn
```

Inside guest/container:

```bash
rocminfo
clinfo || true
python3 -c "import torch; print(torch.cuda.is_available())" || true
```

## 8) Operations and updates

Use this repository helpers from the Proxmox host:

- `scripts/proxmox-install-rocm-ct.sh` for interactive container creation and GPU mapping
- `scripts/proxmox-update-rocm-ct.sh <CTID>` for package updates
- `scripts/proxmox-ai-readiness-check.sh` for host readiness validation
- `ct/rocm-lxc.sh` and `ct/rocm-lxc-update.sh` for curl-style execution
- `ct/rocm-lxc-audit.sh` for curl-style readiness audit

## 9) Troubleshooting quick hits

- GPU not visible in guest: verify all needed PCI functions are passed.
- LXC permission denied on `/dev/dri` or `/dev/kfd`: re-check cgroup2 and mount entries.
- Random slowdowns: check thermal throttling, CPU governor, and host memory pressure.
- ROCm failures after updates: align kernel/userspace/ROCm versions and retest.

## 10) Practical recommendation

For most users targeting both stability and speed:

1. Run heavy AI workloads in a VM with full 7900 XTX passthrough.
2. Keep iGPU for host responsiveness and auxiliary workloads.
3. Use LXC GPU sharing only for lightweight or controlled multi-tenant use.
