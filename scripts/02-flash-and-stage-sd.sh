#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 02-flash-and-stage-sd.sh
# Purpose: Flash Armbian Desktop image to SD/NVMe and stage offline platform assets
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOWNLOADS_DIR="${ROOT_DIR}/downloads"

# Load configuration
if [[ -f "${ROOT_DIR}/env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env"
elif [[ -f "${ROOT_DIR}/env.example" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env.example"
fi

SD_DEVICE="${1:-${SD_DISK:-}}"

# If no device specified or specified device is not a currently valid block device, launch interactive detection
if [[ -z "${SD_DEVICE}" || ! -b "${SD_DEVICE}" ]]; then
    if [[ -n "${SD_DEVICE}" ]]; then
        echo "Target device '${SD_DEVICE}' is not currently connected or is not a valid block device."
    else
        echo "No target storage device specified via DISK= or SD_DISK in env."
    fi
    echo "Scanning and launching interactive storage device selection..."
    echo ""
    "${SCRIPT_DIR}/detect-sd-device.sh"
    # Reload env to obtain newly saved SD_DISK
    if [[ -f "${ROOT_DIR}/env" ]]; then
        # shellcheck disable=SC1091
        source "${ROOT_DIR}/env"
    fi
    SD_DEVICE="${SD_DISK:-}"
fi

if [[ -z "${SD_DEVICE}" ]]; then
    echo "Error: No storage device selected."
    exit 1
fi

if [[ ! -b "${SD_DEVICE}" ]]; then
    echo "Error: Device '${SD_DEVICE}' is not a valid block device. Please check your card reader connection."
    exit 1
fi

# Fetch device details
DEV_SIZE=$(lsblk -d -n -o SIZE "${SD_DEVICE}" 2>/dev/null || echo "Unknown")
DEV_MODEL=$(lsblk -d -n -o MODEL "${SD_DEVICE}" 2>/dev/null || echo "Unknown")
DEV_TRAN=$(lsblk -d -n -o TRAN "${SD_DEVICE}" 2>/dev/null || echo "Unknown")

# Locate Armbian OS Image
OS_IMAGE=$(find "${DOWNLOADS_DIR}" -maxdepth 1 \( -name "Armbian*.img*" -o -name "armbian*.img*" -o -name "*orangepi*.img*" \) ! -name "*.torrent" | head -n 1)

if [[ -z "${OS_IMAGE}" || ! -f "${OS_IMAGE}" ]]; then
    echo "Armbian OS image not found in ${DOWNLOADS_DIR}."
    echo "Running fetch script first..."
    "${SCRIPT_DIR}/01-fetch-assets.sh"
    OS_IMAGE=$(find "${DOWNLOADS_DIR}" -maxdepth 1 \( -name "Armbian*.img*" -o -name "armbian*.img*" -o -name "*orangepi*.img*" \) ! -name "*.torrent" | head -n 1)
    if [[ -z "${OS_IMAGE}" || ! -f "${OS_IMAGE}" ]]; then
        echo "Error: No Armbian image available to flash. Please check ${DOWNLOADS_DIR}."
        exit 1
    fi
fi

echo "======================================================================"
echo "Target Storage Device:  ${SD_DEVICE}"
echo "Device Capacity:        ${DEV_SIZE}"
echo "Device Model:           ${DEV_MODEL}"
echo "Transport / Bus:        ${DEV_TRAN}"
echo "Source OS Image:        ${OS_IMAGE}"
echo "======================================================================"
echo "WARNING: This will completely overwrite all data on ${SD_DEVICE}!"
echo "======================================================================"
read -p "Type 'yes' to proceed with flashing: " -r CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# 1. Unmount existing partitions
echo "[1/5] Unmounting existing partitions on ${SD_DEVICE}..."
sudo umount "${SD_DEVICE}"* 2>/dev/null || true

# 2. Flash OS Image
echo "[2/5] Flashing Armbian Desktop image to ${SD_DEVICE}..."
if [[ "${OS_IMAGE}" == *.xz ]]; then
    xz -dc "${OS_IMAGE}" | sudo dd of="${SD_DEVICE}" bs=4M status=progress conv=fsync
elif [[ "${OS_IMAGE}" == *.gz ]]; then
    gzip -dc "${OS_IMAGE}" | sudo dd of="${SD_DEVICE}" bs=4M status=progress conv=fsync
elif [[ "${OS_IMAGE}" == *.zst ]]; then
    zstd -dc "${OS_IMAGE}" | sudo dd of="${SD_DEVICE}" bs=4M status=progress conv=fsync
else
    sudo dd if="${OS_IMAGE}" of="${SD_DEVICE}" bs=4M status=progress conv=fsync
fi

echo "Syncing disk writes..."
sync

# 3. Reload partition table and locate root partition
echo "[3/5] Inspecting partitions on ${SD_DEVICE}..."
sudo partprobe "${SD_DEVICE}" 2>/dev/null || sudo blockdev --rereadpt "${SD_DEVICE}" 2>/dev/null || true
sleep 2

# Determine partition naming (/dev/sda1 vs /dev/mmcblk0p1)
if [[ "${SD_DEVICE}" =~ [0-9]$ ]]; then
    ROOT_PART="${SD_DEVICE}p1"
else
    ROOT_PART="${SD_DEVICE}1"
fi

if [[ ! -b "${ROOT_PART}" ]]; then
    # Fallback search for first partition
    ROOT_PART=$(lsblk -ln -o PATH "${SD_DEVICE}" | grep -v "^${SD_DEVICE}$" | head -n 1)
fi

echo "Found rootfs partition: ${ROOT_PART}"

# 4. Mount root partition to stage offline assets
echo "[4/5] Staging offline Kubernetes, CLI tools, and desktop shortcuts..."
MOUNT_DIR=$(mktemp -d /tmp/orangepi_rootfs.XXXXXX)

sudo mount "${ROOT_PART}" "${MOUNT_DIR}"

# Create required directories on rootfs
sudo mkdir -p "${MOUNT_DIR}/usr/local/bin"
sudo mkdir -p "${MOUNT_DIR}/var/lib/rancher/k3s/agent/images"
sudo mkdir -p "${MOUNT_DIR}/etc/systemd/system/multi-user.target.wants"
sudo mkdir -p "${MOUNT_DIR}/usr/local/share/uds/desktop-shortcuts"
sudo mkdir -p "${MOUNT_DIR}/etc/skel/Desktop"

# Copy Platform Binaries to /usr/local/bin
for BIN_NAME in k3s k3s-install.sh kubectl helm zarf uds k9s; do
    if [[ -f "${DOWNLOADS_DIR}/${BIN_NAME}" ]]; then
        echo "  -> Staging /usr/local/bin/${BIN_NAME}"
        sudo cp "${DOWNLOADS_DIR}/${BIN_NAME}" "${MOUNT_DIR}/usr/local/bin/"
        sudo chmod +x "${MOUNT_DIR}/usr/local/bin/${BIN_NAME}"
    fi
done

# Copy K3s Airgap Container Images
AIRGAP_TAR=$(find "${DOWNLOADS_DIR}" -maxdepth 1 -name "k3s-airgap-images-arm64.tar*" | head -n 1)
if [[ -n "${AIRGAP_TAR}" && -f "${AIRGAP_TAR}" ]]; then
    echo "  -> Staging K3s airgap images: $(basename "${AIRGAP_TAR}")"
    sudo cp "${AIRGAP_TAR}" "${MOUNT_DIR}/var/lib/rancher/k3s/agent/images/"
fi

# Copy First-Boot systemd initialization service and script
if [[ -f "${ROOT_DIR}/config/firstboot-k3s-init.sh" ]]; then
    echo "  -> Installing firstboot-k3s-init script & systemd service"
    sudo cp "${ROOT_DIR}/config/firstboot-k3s-init.sh" "${MOUNT_DIR}/usr/local/bin/firstboot-k3s-init.sh"
    sudo chmod +x "${MOUNT_DIR}/usr/local/bin/firstboot-k3s-init.sh"
fi

if [[ -f "${ROOT_DIR}/config/firstboot-k3s-init.service" ]]; then
    sudo cp "${ROOT_DIR}/config/firstboot-k3s-init.service" "${MOUNT_DIR}/etc/systemd/system/firstboot-k3s-init.service"
    sudo ln -sf /etc/systemd/system/firstboot-k3s-init.service "${MOUNT_DIR}/etc/systemd/system/multi-user.target.wants/firstboot-k3s-init.service"
fi

# Deterministic User, Hostname, Target IP & Headless Configuration (NIST AC-2 / AC-6)
EDGE_USER="${DEFAULT_USER:-bjarrett}"
EDGE_HOST="${HOSTNAME:-orangepi5pro}"
EDGE_IP="${TARGET_IP:-192.168.42.100}"

# Handle SHA-512 crypt password hashing (NIST IA-5 / 800-63B compliant)
if [[ -n "${DEFAULT_PASSWORD_HASH:-}" ]]; then
    EDGE_PASS_HASH="${DEFAULT_PASSWORD_HASH}"
elif [[ -n "${DEFAULT_PASSWORD:-}" ]]; then
    EDGE_PASS_HASH=$(openssl passwd -6 "${DEFAULT_PASSWORD}")
else
    EDGE_PASS_HASH=$(openssl passwd -6 "1234")
fi

echo "  -> Configuring deterministic user '${EDGE_USER}', hostname '${EDGE_HOST}', static IP '${EDGE_IP}'"

# Write air-gap appliance environment file
sudo mkdir -p "${MOUNT_DIR}/etc/default"
cat << EOF | sudo tee "${MOUNT_DIR}/etc/default/orangepi-airgap" > /dev/null
DEFAULT_USER="${EDGE_USER}"
HOSTNAME="${EDGE_HOST}"
TARGET_IP="${EDGE_IP}"
EOF

# Pre-seed K3s configuration with deterministic host IP and host-gw CNI
sudo mkdir -p "${MOUNT_DIR}/etc/rancher/k3s"
cat << EOF | sudo tee "${MOUNT_DIR}/etc/rancher/k3s/config.yaml" > /dev/null
write-kubeconfig-mode: "0644"
node-ip: "${EDGE_IP}"
advertise-address: "${EDGE_IP}"
flannel-backend: "host-gw"
disable:
  - traefik
  - servicelb
  - local-storage
  - metrics-server
EOF

# 1. Hostname & Hosts Resolution
echo "${EDGE_HOST}" | sudo tee "${MOUNT_DIR}/etc/hostname" > /dev/null
if [[ -f "${MOUNT_DIR}/etc/hosts" ]]; then
    if ! grep -q "${EDGE_IP}" "${MOUNT_DIR}/etc/hosts"; then
        echo -e "127.0.0.1\tlocalhost\n${EDGE_IP}\t${EDGE_HOST}" | sudo tee "${MOUNT_DIR}/etc/hosts" > /dev/null
    fi
fi

# Pre-seed fake-hwclock with host workstation timestamp for airgap RTC bootstrap
echo "$(date -u +'%Y-%m-%d %H:%M:%S')" | sudo tee "${MOUNT_DIR}/etc/fake-hwclock.data" > /dev/null 2>&1 || true

# 2. Static Appliance Networking (NetworkManager + systemd-networkd + ifupdown)
echo "  -> Pre-configuring static maintenance network ${EDGE_IP}/24"
sudo mkdir -p "${MOUNT_DIR}/etc/NetworkManager/system-connections"
cat << EOF | sudo tee "${MOUNT_DIR}/etc/NetworkManager/system-connections/armbian-ethernet.nmconnection" > /dev/null
[connection]
id=Armbian Ethernet
type=ethernet
autoconnect=true

[ipv4]
method=manual
address1=${EDGE_IP}/24,192.168.42.1
dns=1.1.1.1;8.8.8.8;

[ipv6]
method=ignore
EOF
sudo chmod 0600 "${MOUNT_DIR}/etc/NetworkManager/system-connections/armbian-ethernet.nmconnection"

sudo mkdir -p "${MOUNT_DIR}/etc/systemd/network"
cat << EOF | sudo tee "${MOUNT_DIR}/etc/systemd/network/10-static-eth.network" > /dev/null
[Match]
Name=en* eth*

[Network]
Address=${EDGE_IP}/24
Gateway=192.168.42.1
DNS=1.1.1.1 8.8.8.8
EOF
sudo chmod 0644 "${MOUNT_DIR}/etc/systemd/network/10-static-eth.network"

sudo mkdir -p "${MOUNT_DIR}/etc/network/interfaces.d"
cat << EOF | sudo tee "${MOUNT_DIR}/etc/network/interfaces.d/10-static-eth.conf" > /dev/null
allow-hotplug enP4p65s0 eth0
iface enP4p65s0 inet static
    address ${EDGE_IP}
    netmask 255.255.255.0
    gateway 192.168.42.1

iface eth0 inet static
    address ${EDGE_IP}
    netmask 255.255.255.0
    gateway 192.168.42.1
EOF
sudo chmod 0644 "${MOUNT_DIR}/etc/network/interfaces.d/10-static-eth.conf"

# 3. Deterministic User Account Pre-Creation (NIST AC-2 / IA-5)
echo "  -> Pre-creating administrator user '${EDGE_USER}' (UID 1000) in rootfs"
# Add user to /etc/passwd if missing
if ! grep -q "^${EDGE_USER}:" "${MOUNT_DIR}/etc/passwd" 2>/dev/null; then
    echo "${EDGE_USER}:x:1000:1000:${EDGE_USER},,,:/home/${EDGE_USER}:/bin/bash" | sudo tee -a "${MOUNT_DIR}/etc/passwd" > /dev/null
fi

# Add group to /etc/group if missing
if ! grep -q "^${EDGE_USER}:" "${MOUNT_DIR}/etc/group" 2>/dev/null; then
    echo "${EDGE_USER}:x:1000:" | sudo tee -a "${MOUNT_DIR}/etc/group" > /dev/null
fi

# Append user to supplementary groups in /etc/group
for GRP in sudo audio video dialout plugdev users netdev input render; do
    if grep -q "^${GRP}:" "${MOUNT_DIR}/etc/group"; then
        sudo sed -i "/^${GRP}:/ { /${EDGE_USER}/! s/\$/,\${EDGE_USER}/; s/:,/:/ }" "${MOUNT_DIR}/etc/group"
    fi
done

# Set password hashes in /etc/shadow
if grep -q "^${EDGE_USER}:" "${MOUNT_DIR}/etc/shadow" 2>/dev/null; then
    sudo sed -i "s|^${EDGE_USER}:[^:]*:|${EDGE_USER}:${EDGE_PASS_HASH}:|" "${MOUNT_DIR}/etc/shadow"
else
    echo "${EDGE_USER}:${EDGE_PASS_HASH}:19900:0:99999:7:::" | sudo tee -a "${MOUNT_DIR}/etc/shadow" > /dev/null
fi

# Update root password hash
if grep -q "^root:" "${MOUNT_DIR}/etc/shadow" 2>/dev/null; then
    sudo sed -i "s|^root:[^:]*:|root:${EDGE_PASS_HASH}:|" "${MOUNT_DIR}/etc/shadow"
fi

# Pre-create user home directory with UID/GID 1000:1000
sudo mkdir -p "${MOUNT_DIR}/home/${EDGE_USER}"
sudo cp -r "${MOUNT_DIR}/etc/skel/." "${MOUNT_DIR}/home/${EDGE_USER}/" 2>/dev/null || true

# 4. Armbian Headless First-Run Configuration (Bypasses interactive console setup)
ARMBIAN_FIRSTRUN_CONFIG="FR_general_delete_this_file_after_completion=1
FR_net_change_defaults=1
FR_net_wifi_enabled=0
FR_net_use_static=1
FR_net_static_ip=\"${EDGE_IP}\"
FR_net_static_mask=\"255.255.255.0\"
FR_net_static_gateway=\"192.168.42.1\"
FR_net_static_dns=\"1.1.1.1 8.8.8.8\"
FR_general_set_root_password_hash=\"${EDGE_PASS_HASH}\"
FR_general_create_user=1
FR_general_user_username=\"${EDGE_USER}\"
FR_general_user_password_hash=\"${EDGE_PASS_HASH}\"
FR_general_user_realname=\"${EDGE_USER}\"
FR_general_user_shell=\"/bin/bash\"
FR_general_user_groups=\"sudo,audio,video,dialout,plugdev,users,netdev,docker,render,input\"
FR_general_set_hostname=1
FR_general_hostname=\"${EDGE_HOST}\"
FR_general_set_timezone=1
FR_general_timezone=\"UTC\""

sudo mkdir -p "${MOUNT_DIR}/boot"
echo "${ARMBIAN_FIRSTRUN_CONFIG}" | sudo tee "${MOUNT_DIR}/boot/armbian_first_run.txt" > /dev/null
echo "${ARMBIAN_FIRSTRUN_CONFIG}" | sudo tee "${MOUNT_DIR}/armbian_first_run.txt" > /dev/null 2>&1 || true
# Disable Armbian firstrun SSH host key regeneration so pre-seeded deterministic host keys are preserved
sudo mkdir -p "${MOUNT_DIR}/etc/default"
if [[ -f "${MOUNT_DIR}/etc/default/armbian-firstrun" ]]; then
    sudo sed -i 's/^OPENSSHD_REGENERATE_HOST_KEYS=.*/OPENSSHD_REGENERATE_HOST_KEYS=false/' "${MOUNT_DIR}/etc/default/armbian-firstrun"
else
    echo "OPENSSHD_REGENERATE_HOST_KEYS=false" | sudo tee "${MOUNT_DIR}/etc/default/armbian-firstrun" > /dev/null
fi

# Disable unauthenticated root console and serial autologin (NIST AC-2 / AC-3 / AC-6 / IA-2)
sudo rm -rf "${MOUNT_DIR}/etc/systemd/system/getty@.service.d" \
            "${MOUNT_DIR}/etc/systemd/system/serial-getty@.service.d" 2>/dev/null || true
sudo rm -f "${MOUNT_DIR}/root/.not_logged_in_yet" 2>/dev/null || true

# 5. Passwordless Sudo for Deterministic Management (NIST AC-6)
sudo mkdir -p "${MOUNT_DIR}/etc/sudoers.d"
cat << EOF | sudo tee "${MOUNT_DIR}/etc/sudoers.d/99-orangepi-admin" > /dev/null
${EDGE_USER} ALL=(ALL) NOPASSWD:ALL
root ALL=(ALL) NOPASSWD:ALL
EOF
sudo chmod 0440 "${MOUNT_DIR}/etc/sudoers.d/99-orangepi-admin"

# 6. Pre-Seed SSH Public Keys from Host Workstation (NIST IA-2 / AC-17)
echo "  -> Pre-seeding workstation SSH authorized keys"
sudo mkdir -p "${MOUNT_DIR}/root/.ssh" "${MOUNT_DIR}/home/${EDGE_USER}/.ssh" "${MOUNT_DIR}/etc/skel/.ssh"
sudo chmod 700 "${MOUNT_DIR}/root/.ssh" "${MOUNT_DIR}/home/${EDGE_USER}/.ssh" "${MOUNT_DIR}/etc/skel/.ssh"

HOST_SSH_KEYS=""
for KEY_FILE in "${HOME}/.ssh"/*.pub; do
    if [[ -f "${KEY_FILE}" ]]; then
        HOST_SSH_KEYS+="$(cat "${KEY_FILE}")"$'\n'
    fi
done

if [[ -n "${HOST_SSH_KEYS}" ]]; then
    echo -n "${HOST_SSH_KEYS}" | sudo tee -a "${MOUNT_DIR}/root/.ssh/authorized_keys" > /dev/null
    echo -n "${HOST_SSH_KEYS}" | sudo tee -a "${MOUNT_DIR}/home/${EDGE_USER}/.ssh/authorized_keys" > /dev/null
    echo -n "${HOST_SSH_KEYS}" | sudo tee -a "${MOUNT_DIR}/etc/skel/.ssh/authorized_keys" > /dev/null
    sudo chmod 600 "${MOUNT_DIR}/root/.ssh/authorized_keys" "${MOUNT_DIR}/home/${EDGE_USER}/.ssh/authorized_keys" "${MOUNT_DIR}/etc/skel/.ssh/authorized_keys"
fi

# Ensure user home and .ssh have proper UID:GID (1000:1000) ownership
sudo chown -R 1000:1000 "${MOUNT_DIR}/home/${EDGE_USER}" 2>/dev/null || true
sudo chmod 755 "${MOUNT_DIR}/home/${EDGE_USER}"
sudo chmod 700 "${MOUNT_DIR}/home/${EDGE_USER}/.ssh"
sudo chmod 600 "${MOUNT_DIR}/home/${EDGE_USER}/.ssh/authorized_keys" 2>/dev/null || true

# 7. Deterministic SSH Host Key & Known-Hosts Staging (NIST SC-8 / IA-3 / SC-28)
echo "  -> Pre-seeding deterministic SSH host keys and local known_hosts"
mkdir -p "${ROOT_DIR}/keys"
HOST_KEY_FILE="${ROOT_DIR}/keys/ssh_host_ed25519_key"
if [[ ! -f "${HOST_KEY_FILE}" ]]; then
    ssh-keygen -t ed25519 -f "${HOST_KEY_FILE}" -N "" -C "host@${EDGE_HOST}" >/dev/null
    chmod 600 "${HOST_KEY_FILE}"
    chmod 644 "${HOST_KEY_FILE}.pub"
fi

sudo mkdir -p "${MOUNT_DIR}/etc/ssh"
# Remove default/unseeded host keys to enforce deterministic Ed25519 host key exclusively
sudo rm -f "${MOUNT_DIR}/etc/ssh"/ssh_host_* 2>/dev/null || true
sudo cp "${HOST_KEY_FILE}" "${MOUNT_DIR}/etc/ssh/ssh_host_ed25519_key"
sudo cp "${HOST_KEY_FILE}.pub" "${MOUNT_DIR}/etc/ssh/ssh_host_ed25519_key.pub"
sudo chmod 600 "${MOUNT_DIR}/etc/ssh/ssh_host_ed25519_key"
sudo chmod 644 "${MOUNT_DIR}/etc/ssh/ssh_host_ed25519_key.pub"

# Generate local known_hosts for StrictHostKeyChecking
PUB_KEY_CONTENT=$(awk '{print $1, $2}' "${HOST_KEY_FILE}.pub")
echo "${EDGE_IP} ${PUB_KEY_CONTENT}" > "${ROOT_DIR}/known_hosts"
chmod 600 "${ROOT_DIR}/known_hosts"

# 8. NIST SP 800-53 SSH Daemon Hardening (Disables Password Auth over SSH)
echo "  -> Hardening SSH daemon configuration (NIST AC-17 / IA-2 / SC-8)"
sudo mkdir -p "${MOUNT_DIR}/etc/ssh/sshd_config.d"
cat << 'EOF' | sudo tee "${MOUNT_DIR}/etc/ssh/sshd_config.d/99-hardened.conf" > /dev/null
# NIST SP 800-53 / NIST SP 800-63B SSH Hardening
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 6
EOF
sudo chmod 0644 "${MOUNT_DIR}/etc/ssh/sshd_config.d/99-hardened.conf"

# 5. Global Profile Aliases
cat << 'EOF' | sudo tee "${MOUNT_DIR}/etc/profile.d/99-kubernetes-uds.sh" > /dev/null
# Kubernetes & UDS Toolchain Environment
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
alias k='kubectl'
alias k9s='/usr/local/bin/k9s'
alias uds='/usr/local/bin/uds'
alias zarf='/usr/local/bin/zarf'
EOF

# Copy Desktop Shortcuts
if [[ -d "${ROOT_DIR}/config/desktop-shortcuts" ]]; then
    echo "  -> Installing desktop shortcuts for Browser, Terminal, and K9s"
    sudo cp "${ROOT_DIR}/config/desktop-shortcuts/"*.desktop "${MOUNT_DIR}/usr/local/share/uds/desktop-shortcuts/"
    sudo cp "${ROOT_DIR}/config/desktop-shortcuts/"*.desktop "${MOUNT_DIR}/etc/skel/Desktop/"
    sudo mkdir -p "${MOUNT_DIR}/home/${EDGE_USER}/Desktop"
    sudo cp "${ROOT_DIR}/config/desktop-shortcuts/"*.desktop "${MOUNT_DIR}/home/${EDGE_USER}/Desktop/" 2>/dev/null || true
    sudo chmod +x "${MOUNT_DIR}/etc/skel/Desktop/"*.desktop "${MOUNT_DIR}/home/${EDGE_USER}/Desktop/"*.desktop 2>/dev/null || true
fi

# 5. Clean Unmount
echo "[5/5] Finalizing and unmounting root filesystem..."
sync
sudo umount "${MOUNT_DIR}"
rmdir "${MOUNT_DIR}"
sync

echo ""
echo "======================================================================"
echo "Orange Pi SD Card Provisioning Complete!"
echo "======================================================================"
echo "Next Steps:"
echo "1. Eject the SD card and insert it into your Orange Pi."
echo "2. Connect an Ethernet cable between the Orange Pi and your laptop."
echo "3. Power on the Orange Pi."
echo "4. On your laptop, run the commissioning command:"
echo "     make bootstrap"
echo "   (This connects over SSH, syncs the clock, and fetches kubeconfig)"
echo "5. Deploy UDS bundles from your laptop or on-device:"
echo "     make handoff"
echo "======================================================================"
