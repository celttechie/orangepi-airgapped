# ADR 0001: Migrate Base OS from Talos Linux to Armbian Desktop for Standalone Air-Gapped Operation

* **Status**: Accepted
* **Date**: 2026-09-26
* **Deciders**: Platform & Edge Infrastructure Team
* **Target Hardware**: Orange Pi 5 / Orange Pi 5 Pro / Orange Pi 3 LTS

---

## Context and Problem Statement

The original architecture for the Orange Pi provisioning toolkit utilized **Talos Linux** as the base operating system to provide an immutable, minimal, API-driven single-node Kubernetes cluster.

During physical hardware testing on an **Orange Pi 5 Pro** connected to an HDMI monitor, USB keyboard, and mouse, several critical constraints made Talos unsuitable for the target air-gapped use case:

1. **Headless / No Local GUI or Browser**: Talos Linux is strictly a headless, API-managed appliance OS. It does not provide display server capabilities, desktop environment, or graphical web browser. An air-gapped edge node in this environment requires local interaction via HDMI display and peripherals to access UDS/Kubernetes web portals (e.g., Keycloak, NeuVector, Grafana, Istio Ingress) and native terminal sessions without tethering to an external laptop.
2. **Bootloader Mismatch on Rockchip RK3588**: Standard upstream Talos raw disk images (`metal-arm64.raw.xz`) assume an existing UEFI firmware layer (typically in SPI NOR flash) and do not include the board-specific Rockchip secondary program loader (SPL / U-Boot) at the required raw sector offsets. Flashing generic Talos raw images directly to an SD card resulted in an unbootable state (solid red power LED, no HDMI sync).
3. **Operational Friction in Strict Air-Gap**: Deploying UDS Core and Zarf packages required a persistent network bridge to an external laptop running `talosctl` and `kubectl`. A truly self-contained air-gapped appliance must boot, self-initialize its Kubernetes cluster, and allow local operators to immediately launch terminal/browser sessions on the device itself.

---

## Decision Drivers

* **Self-Contained Air-Gapped Usability**: The device must operate 100% standalone with only an HDMI monitor, keyboard, and mouse attached.
* **Local Operator Interface**: Ability to run a native graphical web browser (e.g., Chromium) and terminal emulator to view and manage UDS workloads directly on the device.
* **Native Board Support**: Turnkey bootloader (U-Boot SPL), HDMI display output, and GPU acceleration for Rockchip RK3588/RK3588S (Orange Pi 5/5 Pro) and Allwinner H6 (Orange Pi 3 LTS).
* **Automated Offline Provisioning**: Provisioning scripts on the workstation should prepare the SD card/NVMe drive with the base OS, desktop environment, Kubernetes binaries (K3s/RKE2), container images, CLI tools (`uds`, `zarf`, `kubectl`), and bootstrap configurations pre-loaded.

---

## Considered Options

1. **Option 1: Retain Talos + Require External Laptop Tethering**
   * *Pros*: Maintains immutable OS model and declarative Talos API.
   * *Cons*: Fails requirement for local HDMI display, browser, and standalone air-gapped operation.
2. **Option 2: Armbian Desktop (Ubuntu/Debian ARM64) + K3s / RKE2 (Chosen)**
   * *Pros*:
     * Native Rockchip RK3588 bootloader and HDMI display drivers out of the box.
     * Full desktop environment (XFCE/Gnome) with local web browser and terminal.
     * Proven compatibility with air-gapped K3s/RKE2 and Defense Unicorns UDS/Zarf toolchains.
     * Workstation scripts can flash the OS image, mount the root filesystem, and stage all required platform binaries and offline packages directly onto the storage media before booting.
   * *Cons*: Standard mutable Linux OS requires explicit hardening and baseline lock-down compared to Talos.

---

## Decision Outcome

**Chosen Option: Option 2 — Migrate to Armbian Desktop as the base OS.**

### Target Architecture & Provisioning Workflow

1. **Base OS Image**: Armbian Desktop (Ubuntu 24.04 / Debian Bookworm ARM64) optimized for Orange Pi 5 / 5 Pro.
2. **Pre-Staged SD/NVMe Provisioning**:
   * The host provisioning script writes the Armbian image to the SD card / NVMe drive.
   * The script mounts the newly written root partition and injects:
     * **Kubernetes Engine**: K3s air-gapped ARM64 binary and air-gapped container image tarballs (`/var/lib/rancher/k3s/agent/images/`).
     * **CLI Toolchain**: `kubectl`, `helm`, `zarf`, `uds`, and `k9s` placed in `/usr/local/bin/`.
     * **Desktop Utilities**: Pre-configured browser (Chromium) and terminal with desktop shortcuts and bookmarks pointing to local cluster services (`https://uds.local`, Grafana, NeuVector, Keycloak).
     * **First-Boot Auto-Initialization**: Systemd first-boot service that starts K3s, applies cluster baseline manifests, and configures local networking.
3. **Operator Experience**:
   * Insert SD card into Orange Pi 5 Pro.
   * Power on device -> Boots directly into Armbian Desktop on HDMI display.
   * K3s starts automatically in the background.
   * Operator opens the terminal or browser on-screen and immediately runs `uds deploy` or accesses cluster services locally.

---

## Positive Consequences

* Immediate hardware compatibility with Orange Pi 5 Pro HDMI video output, USB keyboard/mouse, and onboard network controller.
* Complete independence from external laptops or network boot infrastructure.
* Seamless handoff to Defense Unicorns UDS (`uds-platform-prep`) using standard air-gapped K3s / Kubernetes deployment patterns.

## Negative Consequences & Mitigations

* **Operating System Surface**: Armbian is a general-purpose Linux OS rather than a minimal container appliance.
  * *Mitigation*: The provisioning scripts will disable unnecessary background services (e.g., Bluetooth, telemetry, unused daemons) and apply standard Linux system hardening profiles.
* **Storage Footprint**: The desktop image and browser increase the initial SD card footprint.
  * *Mitigation*: Target standard 32GB+ high-endurance MicroSD cards or NVMe SSDs, which provide ample headroom for OS, K3s, and UDS container image bundles.

---

## Related References

* [Defense Unicorns UDS Core Documentation](https://uds.defenseunicorns.com/)
* [Armbian Orange Pi 5 / 5 Pro Releases](https://www.armbian.com/orangepi-5/)
* [K3s Air-Gapped Installation Guide](https://docs.k3s.io/installation/airgap)
