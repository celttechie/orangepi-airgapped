# Orange Pi Air-Gapped Provisioner (`orangepi-airgapped`)

Automated, reproducible bare-metal provisioning toolchain to prepare **Orange Pi (5 Pro, 5, 3 LTS)** single-board computers as standalone, air-gapped **Defense Unicorns UDS (Unified Delivery System)** appliances.

This toolkit configures an **Armbian Desktop (Ubuntu / Debian ARM64)** base OS with native Rockchip GPU/HDMI drivers, a pre-staged **K3s Kubernetes** cluster, offline CLI tools (`uds`, `zarf`, `kubectl`, `helm`, `k9s`), and desktop shortcuts for immediate on-device interaction via an HDMI monitor, keyboard, and mouse.

> [!NOTE]
> See [ADR 0001: Migrate Base OS from Talos Linux to Armbian Desktop](file:///home/bjarrett/Projects/orangepi-airgapped/docs/adr/0001-migrate-base-os-from-talos-to-armbian.md) for the architecture rationale and technical background.

---

## Standalone Air-Gapped Architecture

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ WORKSTATION / LAPTOP (Provisioning Only)                                               │
│                                                                                        │
│ 1. Download Armbian Desktop OS + K3s Airgap Binaries + UDS/Zarf CLIs                   │
│ 2. Flash Armbian image directly to MicroSD / NVMe storage                              │
│ 3. Mount rootfs partition and pre-stage offline platform assets into storage           │
└───────────────────────────────────────────────────┬────────────────────────────────────┘
                                                    │ Insert Flashed Storage Media
                                                    ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ ORANGE PI 5 PRO / 5 / 3 LTS (100% Standalone & Air-Gapped)                             │
│                                                                                        │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ HARDWARE PERIPHERALS: HDMI Monitor + USB Keyboard & Mouse                          │ │
│ ├────────────────────────────────────────────────────────────────────────────────────┤ │
│ │ ARMBIAN DESKTOP (XFCE / GUI)                                                       │ │
│ │ • Native Rockchip RK3588 GPU / HDMI Display Output                                 │ │
│ │ • Web Browser (Chromium) with pre-configured UDS Service Bookmarks                 │ │
│ │ • UDS Terminal with `kubectl`, `uds`, `zarf`, and `k9s` pre-configured             │ │
│ ├────────────────────────────────────────────────────────────────────────────────────┤ │
│ │ SINGLE-NODE KUBERNETES (K3s Engine)                                                │ │
│ │ • Auto-initializes on first boot from pre-staged airgap image tarballs             │ │
│ │ • Hosts UDS Core Platform (Istio, Keycloak, NeuVector, Grafana, Prom)              │ │
│ └────────────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Provisioning Workflow

### 1. Configure Target Model (Optional)
Edit `env` (or copy from `env.example`) to choose your Orange Pi model and tool versions:
```bash
cp env.example env
```
*Default model is `orangepi5-pro` with Armbian Noble Desktop.*

### 2. Fetch Offline Platform Assets
Download the Armbian Desktop OS image, K3s ARM64 binaries and container image tarballs, and CLI toolchains (`uds`, `zarf`, `kubectl`, `helm`, `k9s`):
```bash
make fetch-assets
```
All assets are verified and cached in `downloads/`.

---

### 3. Flash Storage & Pre-Stage Platform Binaries
Insert your MicroSD card or NVMe USB enclosure into your workstation.

#### Determine the Storage Device Path
Identify the target block device assigned by your OS:
1. List block devices:
   ```bash
   lsblk -p -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS
   ```
2. Or check kernel messages right after plugging in the card:
   ```bash
   dmesg | tail -n 20
   ```
* **USB Card Readers / Enclosures**: Usually `/dev/sda`, `/dev/sdb`, etc.
* **Built-in Laptop SD Slots**: Usually `/dev/mmcblk0`.

> [!CAUTION]
> Always specify the **full disk device** (e.g. `/dev/sda` or `/dev/mmcblk0`), **never** an individual partition (e.g. `/dev/sda1`). Confirm you do not select your workstation's internal drive.

#### Flash and Stage in One Command
Run `make flash-sd` specifying your target drive:
```bash
make flash-sd DISK=/dev/sda
```
This automated target:
1. Flashes the Armbian Desktop image to the card.
2. Mounts the card's root partition.
3. Pre-stages `k3s`, `kubectl`, `helm`, `zarf`, `uds`, and `k9s` into `/usr/local/bin/`.
4. Copies K3s air-gapped container images into `/var/lib/rancher/k3s/agent/images/`.
5. Installs the auto-initialization service (`firstboot-k3s-init.service`).
6. Installs Desktop shortcuts for the Web Browser, UDS Terminal, and K9s Cluster Manager.
7. Unmounts and syncs cleanly.

---

### 4. Boot Orange Pi as Standalone Air-Gapped Appliance

1. **Eject & Insert**: Insert the flashed MicroSD card into your Orange Pi.
2. **Connect Peripherals**: Connect your HDMI monitor, USB keyboard, and mouse.
3. **Power On**: Power on the Orange Pi.
4. **Boot Sequence**:
   - The board boots directly into the **Armbian Desktop** on your HDMI monitor.
   - On first boot, the systemd initialization service automatically configures K3s from the offline binaries and container images.
   - Kubeconfig is populated at `/etc/rancher/k3s/k3s.yaml` and `~/.kube/config`.

---

### 5. Deploy UDS Platform Workloads

On the Orange Pi's desktop:

1. **Open Terminal**: Double-click **UDS Terminal** or open a terminal window.
2. **Verify Cluster Readiness**:
   ```bash
   kubectl get nodes
   ```
   *Or launch `k9s` to monitor the cluster in real-time.*
3. **Deploy UDS Bundles**:
   ```bash
   uds deploy <bundle-name>.tar.zst
   ```
4. **Open Web Browser**: Launch the **UDS Core Web Portal** shortcut to access Keycloak, NeuVector, Grafana, and Istio applications locally.

---

## Quick Reference Commands

| Command | Description |
| :--- | :--- |
| `make help` | Show all available make targets |
| `make fetch-assets` | Download Armbian Desktop OS, K3s, and CLI binaries to `downloads/` |
| `make flash-sd DISK=/dev/sdX` | Flash OS and pre-stage offline platform assets to SD/NVMe |
| `make setup-net IFACE=eth0` | [Optional] Configure laptop interface for tethered direct Ethernet |
| `make handoff` | [Optional] Configure `uds-platform-prep` for remote tethered deployment |
| `make status` | Check cluster status via `kubectl` |
| `make clean` | Remove temporary staging directories |

---

## Architecture Decision Records (ADRs)

* [ADR 0001: Migrate Base OS from Talos Linux to Armbian Desktop](file:///home/bjarrett/Projects/orangepi-airgapped/docs/adr/0001-migrate-base-os-from-talos-to-armbian.md)
