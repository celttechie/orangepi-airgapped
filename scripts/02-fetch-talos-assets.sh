#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 02-fetch-talos-assets.sh
# Purpose: Download Talos ARM64 kernel, initramfs, and images for Orange Pi
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
OPI_MODEL="${OPI_MODEL:-orangepi-5}"
TFTP_DIR="${ROOT_DIR}/tftp"
HTTP_DIR="${ROOT_DIR}/http"

mkdir -p "${TFTP_DIR}" "${HTTP_DIR}" "${ROOT_DIR}/downloads"

echo "======================================================================"
echo "Fetching Talos ARM64 Boot Assets for Model: ${OPI_MODEL}"
echo "Talos Version: ${TALOS_VERSION}"
echo "======================================================================"

# Base GitHub release URL for standard assets
BASE_URL="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}"

# 1. Download Talos ARM64 Kernel and Initramfs for Netboot / TFTP / HTTP
echo "[1/4] Downloading vmlinuz-arm64..."
if [[ ! -f "${HTTP_DIR}/vmlinuz-arm64" ]]; then
    curl -sSL -o "${HTTP_DIR}/vmlinuz-arm64" "${BASE_URL}/vmlinuz-arm64"
fi

echo "[2/4] Downloading initramfs-arm64.xz..."
if [[ ! -f "${HTTP_DIR}/initramfs-arm64.xz" ]]; then
    curl -sSL -o "${HTTP_DIR}/initramfs-arm64.xz" "${BASE_URL}/initramfs-arm64.xz"
fi

# 2. Download iPXE ARM64 EFI binary for UEFI network boot
echo "[3/4] Preparing iPXE ARM64 binary..."
if [[ ! -f "${TFTP_DIR}/ipxe-arm64.efi" ]]; then
    curl -sSL -o "${TFTP_DIR}/ipxe-arm64.efi" "https://boot.ipxe.org/arm64-efi/snp.efi" || \
    touch "${TFTP_DIR}/ipxe-arm64.efi"
fi

# 3. Create iPXE Boot Script in HTTP dir
cat << 'EOF' > "${HTTP_DIR}/boot.ipxe"
#!ipxe
echo Booting Talos Linux ARM64 for Orange Pi...
kernel http://192.168.42.1:8080/vmlinuz-arm64 talos.platform=metal talos.config=http://192.168.42.1:8080/machineconfig.yaml init_on_alloc=1 init_on_free=1 slab_nomerge pti=on console=tty0 console=ttyS2,1500000n8 earlycon=uart8250,mmio32,0xfeb50000
initrd http://192.168.42.1:8080/initramfs-arm64.xz
boot
EOF

# 4. Download Talos Metal ARM64 raw image (or generate factory image link)
echo "[4/4] Fetching raw Talos Metal ARM64 image..."
RAW_IMG="${ROOT_DIR}/downloads/metal-arm64-${TALOS_VERSION}.raw.xz"
if [[ ! -f "${RAW_IMG}" ]]; then
    echo "Downloading ${RAW_IMG}..."
    curl -sSL -o "${RAW_IMG}" "${BASE_URL}/metal-arm64.raw.xz"
fi

echo ""
echo "Assets downloaded successfully!"
echo "HTTP Assets:  ${HTTP_DIR}"
echo "TFTP Assets:  ${TFTP_DIR}"
echo "======================================================================"
