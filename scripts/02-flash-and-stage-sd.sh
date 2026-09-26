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

SD_DEVICE="${1:-}"

if [[ -z "${SD_DEVICE}" ]]; then
    echo "Usage: $0 /dev/sdX (or /dev/mmcblkX)"
    echo ""
    echo "Available block devices:"
    lsblk -p -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS
    echo ""
    echo "Please specify the target SD card device (e.g., $0 /dev/sda)"
    exit 1
fi

if [[ ! -b "${SD_DEVICE}" ]]; then
    echo "Error: Device '${SD_DEVICE}' is not a valid block device."
    exit 1
fi

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
echo "WARNING: This will completely overwrite all data on ${SD_DEVICE}!"
echo "Image:  ${OS_IMAGE}"
echo "Target: ${SD_DEVICE}"
echo "======================================================================"
read -p "Type 'yes' to proceed: " -r CONFIRM

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

# Copy Desktop Shortcuts
if [[ -d "${ROOT_DIR}/config/desktop-shortcuts" ]]; then
    echo "  -> Installing desktop shortcuts for Browser, Terminal, and K9s"
    sudo cp "${ROOT_DIR}/config/desktop-shortcuts/"*.desktop "${MOUNT_DIR}/usr/local/share/uds/desktop-shortcuts/"
    sudo cp "${ROOT_DIR}/config/desktop-shortcuts/"*.desktop "${MOUNT_DIR}/etc/skel/Desktop/"
    if [[ -d "${MOUNT_DIR}/home/armbian" ]]; then
        sudo mkdir -p "${MOUNT_DIR}/home/armbian/Desktop"
        sudo cp "${ROOT_DIR}/config/desktop-shortcuts/"*.desktop "${MOUNT_DIR}/home/armbian/Desktop/"
    fi
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
echo "1. Insert the MicroSD card into your Orange Pi 5 Pro."
echo "2. Connect your HDMI monitor, USB keyboard, and mouse."
echo "3. Power on the Orange Pi."
echo "4. The board will boot directly into Armbian Desktop."
echo "   - K3s will initialize automatically in the background."
echo "   - Open Terminal or Browser from the Desktop to begin UDS deployment!"
echo "======================================================================"
