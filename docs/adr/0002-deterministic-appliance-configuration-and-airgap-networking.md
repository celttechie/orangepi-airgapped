# ADR 0002: Deterministic Appliance Configuration, Pre-Seeded Zero-Touch Credentials, and Air-Gapped K3s Networking

* **Status**: Accepted
* **Date**: 2026-09-29
* **Decision-Makers**: Core Architecture Team
* **Context**: Orange Pi 5 Pro Standalone Air-Gapped Kubernetes Appliance (`orangepi-airgapped`)

---

## Context and Problem Statement

When provisioning the standalone air-gapped Armbian Desktop image on the Orange Pi 5 Pro, two primary operational friction points were identified:

1. **Interactive Console User Prompt vs. Zero-Touch Edge Provisioning**:
   - By default, Armbian launches an interactive first-boot terminal wizard (`armbian-firstrun`) prompting for a root password, a new regular username, and real names.
   - For an automated edge appliance, forcing an operator to attach an HDMI monitor and keyboard to create arbitrary usernames violates zero-touch provisioning (ZTP), prevents unattended headless boots, breaks automated pipeline testing, and causes inconsistencies across deployments.

2. **Kubernetes Loopback Binding vs. Air-Gapped CNI Requirements**:
   - In standard Linux installations, `/etc/hosts` resolves the machine hostname to `127.0.1.1` or `::1`.
   - Kubernetes' networking model mandates that all pods receive unique routable IPs within a cluster CIDR (`10.42.0.0/16`) and that a host network bridge (`cni0`) binds to a valid host interface.
   - The Linux kernel prohibits routing virtual container bridges across loopback (`127.0.0.0/8` / `lo`). When K3s or Flannel binds to loopback (`127.0.0.1`), Kubelet node lease synchronizations fail with `NodeStatusUnknown`, pod scheduling halts, and the node remains permanently `NotReady`.

---

## Decision Drivers

* **Zero-Touch Provisioning (ZTP)**: Flashed SD/NVMe storage devices must boot autonomously into a fully functioning, headless-capable Kubernetes appliance with zero interactive setup.
* **Predictable Maintenance Access**: Support tethered field connections (e.g. laptop-to-SBC via Ethernet) with immediate passwordless SSH access, pre-seeded keys, and predictable static IPs.
* **Deterministic Kubernetes CNI & Cluster Topology**: The K3s control plane, Kubelet agent, and Flannel CNI must bind to a fixed, non-loopback network endpoint with `host-gw` routing that functions seamlessly both when tethered and when operating fully offline/unplugged.
* **Reproducibility**: All configurations (users, passwords, hostname, static IPs, and SSH authorized keys) must be declared deterministically in `env` and baked during flashing.

---

## Considered Options

1. **Option 1: Dynamic User Discovery & DHCP-Only Networking**
   - *Pros*: Flexible for ad-hoc interactive setups.
   - *Cons*: Fails headless booting (hangs on Armbian first-run prompt); requires external DHCP router in air-gapped field environments; causes CNI failures when disconnected.

2. **Option 2: Deterministic Pre-Seeding with Fixed Maintenance IP & Host-GW CNI (Chosen)**
   - *Pros*:
     - Pre-seeds deterministic user (`DEFAULT_USER="bjarrett"`), passwordless sudo, and workstation SSH public keys at flash time.
     - Utilizes `/boot/armbian_first_run.txt` to completely bypass the interactive console setup.
     - Configures a deterministic static maintenance IP (`192.168.42.100/24`) and maps `/etc/hosts` accordingly.
     - Pre-configures K3s with `node-ip: 192.168.42.100` and `flannel-backend: host-gw`, ensuring node state is immediately `Ready` and system pods (`coredns`, `metrics-server`) schedule reliably.
     - Operates reliably whether connected to a maintenance laptop or running standalone/unplugged.
   - *Cons*: Requires static IP management on the tethered maintenance workstation (`192.168.42.1/24`), which is already automated via `make setup-net`.

---

## Decision Outcome

**Chosen Option: Option 2 (Deterministic Pre-Seeding, Fixed Maintenance IP, and Host-GW CNI)**.

### Architectural Specification:

### 1. Zero-Touch Headless First-Boot (`armbian_first_run.txt`)
During `scripts/02-flash-and-stage-sd.sh`, the root filesystem is mounted and populated with `/boot/armbian_first_run.txt` containing:
* `FR_general_set_root_password="${DEFAULT_PASSWORD}"`
* `FR_general_create_user=1`
* `FR_general_user_username="${DEFAULT_USER}"`
* `FR_general_user_password="${DEFAULT_PASSWORD}"`
* `FR_general_set_hostname=1`
* `FR_general_hostname="${HOSTNAME}"`

### 2. Pre-Seeded Credentials & NIST SP 800-53 / 800-63B Hardening
* **Elimination of Plaintext Authenticators (IA-5(1))**:
  - Plaintext passwords are never written to repository files, SD storage, or version control.
  - Interactive setup (`make config` / `scripts/00-configure.sh`) transforms operator passwords into salted **SHA-512 crypt hashes** (`openssl passwd -6`) conforming to NIST SP 800-63B.
  - Armbian headless setup consumes `FR_general_set_root_password_hash` and `FR_general_user_password_hash` directly.
* **PKI / Asymmetric Key Authentication (IA-2(1), IA-2(2), AC-17, IA-3, SC-8)**:
  - Workstation public keys (`~/.ssh/*.pub` or dedicated Ed25519 `~/.ssh/id_ed25519_orangepi.pub`) are injected into `/root/.ssh/authorized_keys`, `/home/${DEFAULT_USER}/.ssh/authorized_keys`, and `/etc/skel/.ssh/authorized_keys` with strict `0700`/`0600` permissions.
  - **Deterministic Host Key Pinning & MITM Prevention (NIST SC-8 / IA-3)**: An Ed25519 host key is deterministically generated at `keys/ssh_host_ed25519_key` and baked into `/etc/ssh/ssh_host_ed25519_key` on the target rootfs. Workstation client connections pin this key in `./known_hosts` and enforce `StrictHostKeyChecking=yes`, preventing Man-in-the-Middle (MITM) attacks during tethered maintenance.
  - SSH daemon hardening (`/etc/ssh/sshd_config.d/99-hardened.conf`) enforces:
    ```text
    HostKey /etc/ssh/ssh_host_ed25519_key
    PasswordAuthentication no
    PermitRootLogin prohibit-password
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    X11Forwarding no
    MaxAuthTries 6
    ```
* **Least Privilege & Access Enforcement (AC-2, AC-3, AC-6)**:
  - Direct root password logins and unauthenticated console root autologin are disabled (`getty@.service.d` / `serial-getty@.service.d` overrides removed).
  - Physical and serial consoles require explicit operator authentication (`bjarrett` with SHA-512 hashed password).
  - Named administrator (`DEFAULT_USER`) is granted passwordless sudo via `/etc/sudoers.d/99-orangepi-admin` with mode `0440`.
  - Local configuration files (`env`) are restricted to mode `0600` and ignored by `.gitignore`.

### 3. Deterministic Air-Gap Networking & K3s CNI
* **Deterministic Appliance IP**: Default `192.168.42.100/24`.
* **Host Mapping**: `/etc/hosts` explicitly maps `192.168.42.100` to `${HOSTNAME}`.
* **Airgap Clock Seeding**: Pre-seeds `/etc/fake-hwclock.data` during SD staging with the host machine's UTC timestamp to prevent x509 TLS certificate generation failures on battery-less SBCs.
* **K3s Engine Configuration (`/etc/rancher/k3s/config.yaml`)**:
  ```yaml
  write-kubeconfig-mode: "0644"
  node-ip: "192.168.42.100"
  advertise-address: "192.168.42.100"
  flannel-backend: "host-gw"
  disable:
    - traefik
    - servicelb
    - local-storage
    - metrics-server
  ```
* **Routing Priority**: Eliminate fallback loopback default routes (`lo metric 1000`) that override the physical NIC in the kernel routing table.

---

## NIST SP 800-53 (Rev. 5) Security Control Traceability

| Control ID | Control Family & Title | Technical Implementation |
| :--- | :--- | :--- |
| **IA-2 / IA-2(1)** | *Identification and Authentication (Organizational Users / Network)* | Administrative SSH management uses asymmetric **Ed25519 / RSA $\ge 3072$-bit** public key cryptography. |
| **IA-3 / SC-8** | *Device Identification & Transmission Integrity (MITM Prevention)* | Appliance SSH host key is deterministically generated and pinned in `./known_hosts`; client connections enforce `StrictHostKeyChecking=yes`. |
| **IA-5(1)** | *Authenticator Management (Password Hashing)* | Passwords are salted and hashed via **SHA-512 crypt** (`$6$`) per NIST SP 800-63B §5.1.1.2. Zero plaintext secrets in git or storage. |
| **IA-5(2)** | *PKI-Based Authentication* | Kubernetes API and cluster components communicate via dedicated mutual TLS (mTLS) with dedicated x509 CAs. |
| **AC-2 / AC-3** | *Account Management & Access Enforcement* | Automated deterministic account creation (`DEFAULT_USER`), strict POSIX permissions (`0600` on credentials, `0440` on sudoers). |
| **AC-6 / AC-6(1)** | *Least Privilege* | Direct root SSH login disabled (`PermitRootLogin prohibit-password`). All admin actions require named user attribution and sudo logging. |
| **AC-17 / SC-8** | *Remote Access & Transmission Confidentiality* | Network transport is strictly encrypted over SSHv2 (management) and TLS 1.3 mTLS (Kubernetes API port 6443). |
| **CM-6 / CM-7** | *Configuration Settings & Least Functionality* | Minimal footprint: unneeded services (Traefik, Klipper-LB, local-storage, metrics-server) disabled in K3s engine. |
| **SC-28(1)** | *Protection of Information at Rest* | `.gitignore` excludes local `env` and `keys/`; sensitive authenticators stored only in salted cryptographic hashes. |

---

## Consequences

### Positive
* **NIST SP 800-53 & 800-63B Compliance**: Full alignment with federal identity and edge security baselines.
* **Zero-Touch Headless Deployment**: The SD card can be flashed and booted without monitor, keyboard, or interactive wizards.
* **Predictable Maintenance Tethering**: Operators connect via Ethernet, run `make bootstrap`, and immediately commission K3s with synchronized time.
* **Instant Cluster Health**: K3s initializes with `host-gw` CNI and reaches `Ready` state reliably with running CoreDNS.

### Neutral / Trade-offs
* Password authentication over SSH is disabled by default; operators must have their SSH public key configured in `env` / `~/.ssh/` (automated via `make config`).
