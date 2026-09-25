#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 03-create-sd-bootstrap.sh
# Purpose: Flash Talos ARM64 image to MicroSD card for initial boot
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration
if [[ -f "${ROOT_DIR}/env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env"
elif [[ -f "${ROOT_DIR}/env.example" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env.example"
fi

TALOS_VERSION="${TALOS_VERSION:-v1.7.5}"
SD_DEVICE="${1:-}"

if [[ -z "${SD_DEVICE}" ]]; then
    echo "Usage: $0 /dev/sdX (or /dev/mmcblkX)"
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL
    echo ""
    echo "Please specify the target SD card device (e.g., $0 /dev/sdb)"
    exit 1
fi

if [[ ! -b "${SD_DEVICE}" ]]; then
    echo "Error: Device ${SD_DEVICE} is not a valid block device."
    exit 1
fi

RAW_IMG="${ROOT_DIR}/downloads/metal-arm64-${TALOS_VERSION}.raw.xz"
if [[ ! -f "${RAW_IMG}" ]]; then
    echo "Raw image not found at ${RAW_IMG}. Running fetch script first..."
    "${SCRIPT_DIR}/02-fetch-talos-assets.sh"
fi

echo "======================================================================"
echo "WARNING: This will completely overwrite all data on ${SD_DEVICE}!"
echo "Image:  ${RAW_IMG}"
echo "Target: ${SD_DEVICE}"
echo "======================================================================"
read -p "Type 'yes' to proceed: " -r CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo "Unmounting existing partitions on ${SD_DEVICE}..."
sudo umount "${SD_DEVICE}"* 2>/dev/null || true

echo "Flashing Talos ARM64 image directly to ${SD_DEVICE}..."
xz -dc "${RAW_IMG}" | sudo dd of="${SD_DEVICE}" bs=4M status=progress conv=fsync

echo "Syncing disks..."
sync

echo ""
echo "MicroSD card successfully created!"
echo "Next steps:"
echo "1. Insert the MicroSD card into your Orange Pi."
echo "2. Connect the Ethernet cable between your laptop and the Orange Pi."
echo "3. Power on the Orange Pi."
echo "4. Run 'make start-boot-server' or 'make bootstrap'."
echo "======================================================================"
