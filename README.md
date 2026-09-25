# Orange Pi Talos PXE & Direct-Attached Provisioner (`orangepi-pxe-provisioner`)

Automated, reproducible bare-metal provisioning toolchain to boot, install, and configure **Talos Linux (Kubernetes)** on **Orange Pi (5, 5 Pro, 3 LTS)** single-board computers directly attached to a laptop network port, preparing them for standalone air-gapped **Defense Unicorns UDS (Unified Delivery System)** and **Zarf** deployments.

---

## Architecture & Workflow

```
┌───────────────────────────────────────────────────────────────────────────┐
│ LAPTOP (Direct Ethernet: 192.168.42.1/24)                                 │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ 1. Boot Services (Docker Compose)                                   │  │
│  │    • Dnsmasq: Local DHCP Server + TFTP                              │  │
│  │    • Nginx: HTTP asset server (Talos ARM64 kernel, initramfs, cfg)  │  │
│  └─────────────────────────────────┬───────────────────────────────────┘  │
│                                    │ DHCP IP (192.168.42.100)             │
│  ┌─────────────────────────────────▼───────────────────────────────────┐  │
│  │ 2. Talos Provisioning (talosctl)                                    │  │
│  │    • Injects single-node edge MachineConfig                         │  │
│  │    • Installs Talos to MicroSD (/dev/mmcblk0)                       │  │
│  │    • Bootstraps etcd & pulls kubeconfig                             │  │
│  └─────────────────────────────────┬───────────────────────────────────┘  │
│                                    │ Kubeconfig & Target Configuration    │
│  ┌─────────────────────────────────▼───────────────────────────────────┐  │
│  │ 3. UDS Handoff (`uds-platform-prep`)                                │  │
│  │    • Runs `zarf init` with ARM64 packages                           │  │
│  │    • Deploys UDS bundles across the direct link                     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────┬──────────────────────────────────────┘
                                     │ Direct RJ45 Ethernet (Auto-MDIX)
                                     ▼
┌───────────────────────────────────────────────────────────────────────────┐
│ ORANGE PI (e.g. Orange Pi 5 / 5 Pro / 3 LTS)                              │
│ • Boots Talos Linux from MicroSD / Netboot                                │
│ • Runs standalone single-node Kubernetes cluster                          │
│ • Runs Zarf & UDS Core / platform workloads                               │
│ • Unplug cable -> Operates 100% standalone & air-gapped                   │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start Step-by-Step

### 1. Configure Settings
Copy `env.example` to `env` and adjust your network interface (e.g., `eth0` or `enp0s31f6`):
```bash
cp env.example env
```

### 2. Configure Laptop Network Port
Assigns static IP `192.168.42.1/24` to your laptop Ethernet port:
```bash
make setup-net IFACE=eth0
```

### 3. Fetch Talos ARM64 Assets
Downloads the official Talos kernel, initramfs, and images:
```bash
make fetch-assets
```

### 4. Flash MicroSD Card (Recommended Bootstrap Method)
Insert your MicroSD card into your laptop card reader and flash it:
```bash
make flash-sd DISK=/dev/sdb
```
*(Replace `/dev/sdb` with your SD card device path).*

### 5. Start Laptop Boot Server & Boot the Orange Pi
Start the DHCP and HTTP asset server on the laptop:
```bash
make start-server
```
Insert the MicroSD card into the Orange Pi, plug the standard Ethernet cable directly between the laptop and Orange Pi, and power on the board.

### 6. Bootstrap Kubernetes & Retrieve Kubeconfig
Once the board gets its IP (`192.168.42.100`), bootstrap the cluster:
```bash
make bootstrap
```

### 7. Handoff to `uds-platform-prep`
Hand off the ready cluster to `uds-platform-prep` to deploy Zarf and UDS bundles:
```bash
make handoff
```
Then navigate to `uds-platform-prep` to complete your UDS deployment:
```bash
cd ../uds-platform-prep
make download ARCH=arm64
make deploy
```

---

## Hardware Notes

* **No Crossover Cable Required**: Modern Gigabit Ethernet controllers on both laptops and Orange Pi boards feature automatic MDI/MDI-X crossover detection.
* **Orange Pi 5 & 5 Pro (8GB / 16GB / 32GB)**: Ideal targets for full UDS Core platform suites (Istio, Keycloak, Prometheus, Fluentbit).
* **Orange Pi 3 LTS (2GB)**: Suitable for lightweight single-node workloads or edge K3s agents.
