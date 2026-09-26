# Orange Pi Air-Gapped Provisioner (`orangepi-airgapped`)

Automated, reproducible bare-metal provisioning toolchain to boot, install, and configure **Talos Linux (Kubernetes)** on **Orange Pi (5, 5 Pro, 3 LTS)** single-board computers, preparing them for standalone air-gapped **Defense Unicorns UDS (Unified Delivery System)** and **Zarf** deployments.

This toolkit supports **two provisioning methods**:
1. **Direct Storage Flash (Recommended for Quick Air-Gapped Setup)**: Flash Talos directly to MicroSD or NVMe from your laptop. Insert into the Orange Pi and boot directly without needing any laptop netboot services.
2. **True Network / PXE Boot (For Testing Diskless Netboot)**: Boot the Orange Pi over the network via onboard SPI NOR Flash (or netboot stage-1 loader) using the laptop's local DHCP, TFTP, and HTTP boot services.

---

## Architecture & Provisioning Options

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ LAPTOP (Direct Ethernet: 192.168.42.1/24 or Standalone Card Reader)                    │
│                                                                                        │
│ ┌──────────────────────────────────────┐     ┌──────────────────────────────────────┐  │
│ │ OPTION 1: DIRECT STORAGE FLASH       │     │ OPTION 2: PXE / NETWORK BOOT         │  │
│ │ • Flash raw Talos image to SD/NVMe   │     │ • Laptop runs DHCP, TFTP & HTTP      │  │
│ │ • Pre-load machine config            │     │ • Serves Talos kernel & initramfs    │  │
│ │ • No laptop boot server required     │     │ • Orange Pi SPI/U-Boot boots over NIC│  │
│ └──────────────────┬───────────────────┘     └──────────────────┬───────────────────┘  │
└────────────────────┼────────────────────────────────────────────┼──────────────────────┘
                     │ Flash SD / NVMe Card                       │ Direct RJ45 Ethernet
                     ▼                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ ORANGE PI (Orange Pi 5 / 5 Pro / 3 LTS)                                                │
│ • Runs hardened Talos Linux (Single-Node Kubernetes)                                   │
│ • Zero OS drift, immutable, API-managed                                                │
│ • Runs Zarf & UDS Core / platform workloads                                            │
│ • Unplug cable -> Operates 100% standalone & air-gapped                                │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Workflow 1: Direct Storage Flash (Zero-Netboot)

*Best if you are already flashing an SD card or NVMe drive from your laptop and want the simplest, self-contained air-gapped boot.*

### 1. Fetch Talos Assets
```bash
make fetch-assets
```

### 2. Flash MicroSD or NVMe Drive
Insert your MicroSD card or NVMe USB enclosure into your laptop:
```bash
make flash-sd DISK=/dev/sdb
```
*(Replace `/dev/sdb` with your card's device path).*

### 3. Connect & Power On
1. Insert the card into your Orange Pi.
2. Connect an Ethernet cable between your laptop and Orange Pi (or plug into your local switch).
3. Power on the Orange Pi.

### 4. Configure & Bootstrap Kubernetes
Configure the static link and generate/apply the Talos machine configuration:
```bash
make setup-net IFACE=eth0
make bootstrap
```

### 5. Handoff to `uds-platform-prep`
```bash
make handoff
```

---

## Workflow 2: True Network / PXE Boot

*Best for testing diskless network booting or wiping/reprovisioning nodes over the wire without swapping SD cards.*

### How PXE Works on Orange Pi
Unlike x86 motherboards, ARM SoC ROMs do not have Ethernet drivers baked into silicon. True diskless PXE is achieved on **Orange Pi 5 / 5 Pro / 5 Plus** by flashing U-Boot / UEFI to the board's onboard **SPI NOR Flash** once. From then on, the board boots from SPI flash, initializes the NIC, requests DHCP, and loads Talos over TFTP/HTTP without needing an SD card.

### 1. Configure Laptop Network Port
```bash
make setup-net IFACE=eth0
```

### 2. Fetch Assets & Start Boot Server
```bash
make fetch-assets
make start-pxe
```
This starts Docker containers for **Dnsmasq** (DHCP + TFTP serving `ipxe-arm64.efi`) and **Nginx** (HTTP serving `vmlinuz-arm64`, `initramfs-arm64.xz`, and `machineconfig.yaml`).

### 3. Boot Orange Pi Over Network
* Connect the Orange Pi to the laptop Ethernet port.
* Power on the Orange Pi (with SPI Flash bootloader enabled).
* The board receives IP `192.168.42.100`, downloads the Talos kernel via HTTP, and boots Talos in RAM.

### 4. Bootstrap Kubernetes
```bash
make bootstrap
make handoff
```

### 5. Stop Boot Server
```bash
make stop-pxe
```

---

## Quick Reference Commands

| Command | Description |
| :--- | :--- |
| `make help` | Show all available targets |
| `make fetch-assets` | Download Talos ARM64 kernel, initramfs, and raw images |
| `make flash-sd DISK=/dev/sdX` | Flash Talos image directly to MicroSD/NVMe |
| `make setup-net IFACE=eth0` | Assign static `192.168.42.1/24` to laptop Ethernet port |
| `make start-pxe` | Start DHCP, TFTP, and HTTP netboot servers |
| `make stop-pxe` | Stop netboot servers |
| `make bootstrap` | Generate machine configs, apply to Orange Pi, retrieve `kubeconfig` |
| `make handoff` | Export kubeconfig and configure `uds-platform-prep` |
| `make status` | Verify Kubernetes node and cluster health |
| `make clean` | Remove generated cluster secrets and configs |

---

## Hardware Notes

* **Automatic MDI/MDI-X**: Standard RJ45 Ethernet patch cables work for direct laptop-to-board connections; no crossover cable is needed.
* **Orange Pi 5 / 5 Pro (8GB - 32GB)**: Recommended target for full UDS Core platform suites (Istio, Keycloak, Prometheus, Grafana, NeuVector).
* **Orange Pi 3 LTS (2GB)**: Suitable for lightweight edge workloads.
