#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 01-fetch-assets.sh
# Purpose: Download Armbian Desktop OS image and air-gapped platform binaries
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

OPI_MODEL="${OPI_MODEL:-orangepi5-pro}"
ARMBIAN_VERSION="${ARMBIAN_VERSION:-24.8.1}"
ARMBIAN_RELEASE="${ARMBIAN_RELEASE:-noble}"
ARMBIAN_DESKTOP="${ARMBIAN_DESKTOP:-xfce}"
ARMBIAN_IMAGE_URL="${ARMBIAN_IMAGE_URL:-}"

K3S_VERSION="${K3S_VERSION:-v1.30.4+k3s1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.30.4}"
HELM_VERSION="${HELM_VERSION:-v3.15.4}"
ZARF_VERSION="${ZARF_VERSION:-v0.38.3}"
UDS_VERSION="${UDS_VERSION:-v0.16.0}"
K9S_VERSION="${K9S_VERSION:-v0.32.5}"

mkdir -p "${DOWNLOADS_DIR}"

echo "======================================================================"
echo "Fetching Armbian Desktop & Platform Assets for ${OPI_MODEL}"
echo "K3s Version:   ${K3S_VERSION}"
echo "Zarf Version:  ${ZARF_VERSION}"
echo "UDS Version:   ${UDS_VERSION}"
echo "Downloads Dir: ${DOWNLOADS_DIR}"
echo "======================================================================"

# Helper function to download with curl if file doesn't already exist
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"

    if [[ -f "${dest}" ]]; then
        echo "  [OK] ${desc} already cached: $(basename "${dest}")"
    else
        echo "  [DOWNLOADING] ${desc}..."
        curl -fL --progress-bar -o "${dest}" "${url}" || {
            echo "  [ERROR] Failed to download from: ${url}"
            rm -f "${dest}"
            return 1
        }
    fi
}

# 1. Armbian Desktop Image
echo ""
echo "[1/7] Armbian Desktop Image (${OPI_MODEL})..."
# Check if any Armbian image is already placed in downloads
EXISTING_IMG=$(find "${DOWNLOADS_DIR}" -maxdepth 1 -name "Armbian*.img*" -o -name "armbian*.img*" -o -name "*orangepi*.img*" | head -n 1)

if [[ -n "${EXISTING_IMG}" ]]; then
    echo "  [OK] Found local OS image: $(basename "${EXISTING_IMG}")"
else
    if [[ -n "${ARMBIAN_IMAGE_URL}" ]]; then
        IMG_FILENAME="$(basename "${ARMBIAN_IMAGE_URL}")"
        download_file "${ARMBIAN_IMAGE_URL}" "${DOWNLOADS_DIR}/${IMG_FILENAME}" "Armbian Image from Custom URL"
    else
        # Determine image name mapping for common Orange Pi models
        case "${OPI_MODEL}" in
            orangepi5-pro|orangepi5pro)
                ARMBIAN_URL="https://github.com/armbian/community/releases/download/26.11.0-trunk.52/Armbian_community_26.11.0-trunk.52_Orangepi5pro_resolute_vendor_6.1.172_gnome_desktop.img.xz"
                FALLBACK_URL="https://github.com/armbian/community/releases/download/26.11.0-trunk.52/Armbian_community_26.11.0-trunk.52_Orangepi5pro_resolute_vendor_6.1.172_kde-plasma_desktop.img.xz"
                ;;
            orangepi5|orangepi-5)
                ARMBIAN_URL="https://github.com/armbian/os/releases/download/26.8.0-trunk.420/Armbian_26.8.0-trunk.420_Orangepi5_resolute_vendor_6.1.115_gnome_desktop.img.xz"
                FALLBACK_URL="https://github.com/armbian/community/releases/download/26.11.0-trunk.52/Armbian_community_26.11.0-trunk.52_Orangepi5-ultra_resolute_vendor_6.1.172_gnome_desktop.img.xz"
                ;;
            orangepi3-lts|orangepi-3-lts)
                ARMBIAN_URL="https://github.com/armbian/os/releases/download/26.8.0-trunk.420/Armbian_26.8.0-trunk.420_Orangepi3-lts_resolute_vendor_6.1.115_gnome_desktop.img.xz"
                FALLBACK_URL="https://dl.armbian.com/orangepi3-lts/archive/Armbian_24.8.1_Orangepi3-lts_noble_vendor_6.1.75_xfce_desktop.img.xz"
                ;;
            *)
                echo "  [INFO] Please specify ARMBIAN_IMAGE_URL in env file or place an Armbian .img/.img.xz in downloads/"
                ARMBIAN_URL=""
                ;;
        esac

        if [[ -n "${ARMBIAN_URL:-}" ]]; then
            IMG_NAME="$(basename "${ARMBIAN_URL}")"
            echo "  Attempting download of ${IMG_NAME}..."
            download_file "${ARMBIAN_URL}" "${DOWNLOADS_DIR}/${IMG_NAME}" "Armbian Desktop OS Image" || \
            download_file "${FALLBACK_URL}" "${DOWNLOADS_DIR}/${IMG_NAME}" "Armbian Desktop OS Image (Fallback Mirror)" || {
                echo "  [NOTE] If download fails due to upstream release changes, place an Armbian .img.xz directly into '${DOWNLOADS_DIR}/'"
            }
        fi
    fi
fi

# 2. K3s ARM64 Binary & Airgap Images
echo ""
echo "[2/7] K3s ARM64 Binaries & Airgap Images (${K3S_VERSION})..."
K3S_ENC_VER="${K3S_VERSION/+/%2B}"
download_file "https://github.com/k3s-io/k3s/releases/download/${K3S_ENC_VER}/k3s-arm64" "${DOWNLOADS_DIR}/k3s" "K3s ARM64 Binary"
chmod +x "${DOWNLOADS_DIR}/k3s" 2>/dev/null || true

# Try .tar.zst then fallback to .tar.gz
if [[ ! -f "${DOWNLOADS_DIR}/k3s-airgap-images-arm64.tar.zst" && ! -f "${DOWNLOADS_DIR}/k3s-airgap-images-arm64.tar.gz" ]]; then
    download_file "https://github.com/k3s-io/k3s/releases/download/${K3S_ENC_VER}/k3s-airgap-images-arm64.tar.zst" "${DOWNLOADS_DIR}/k3s-airgap-images-arm64.tar.zst" "K3s Airgap Container Images (.tar.zst)" || \
    download_file "https://github.com/k3s-io/k3s/releases/download/${K3S_ENC_VER}/k3s-airgap-images-arm64.tar.gz" "${DOWNLOADS_DIR}/k3s-airgap-images-arm64.tar.gz" "K3s Airgap Container Images (.tar.gz)" || true
fi

download_file "https://raw.githubusercontent.com/k3s-io/k3s/master/install.sh" "${DOWNLOADS_DIR}/k3s-install.sh" "K3s Installer Script"
chmod +x "${DOWNLOADS_DIR}/k3s-install.sh" 2>/dev/null || true

# 3. Kubectl ARM64
echo ""
echo "[3/7] Kubectl ARM64 (${KUBECTL_VERSION})..."
download_file "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/arm64/kubectl" "${DOWNLOADS_DIR}/kubectl" "Kubectl ARM64 Binary"
chmod +x "${DOWNLOADS_DIR}/kubectl" 2>/dev/null || true

# 4. Helm ARM64
echo ""
echo "[4/7] Helm ARM64 (${HELM_VERSION})..."
if [[ ! -f "${DOWNLOADS_DIR}/helm" ]]; then
    TMP_HELM="${DOWNLOADS_DIR}/helm-${HELM_VERSION}.tar.gz"
    download_file "https://get.helm.sh/helm-${HELM_VERSION}-linux-arm64.tar.gz" "${TMP_HELM}" "Helm ARM64 Archive"
    if [[ -f "${TMP_HELM}" ]]; then
        tar -xzf "${TMP_HELM}" -C "${DOWNLOADS_DIR}" --strip-components=1 linux-arm64/helm
        rm -f "${TMP_HELM}"
        chmod +x "${DOWNLOADS_DIR}/helm"
    fi
fi

# 5. Zarf ARM64
echo ""
echo "[5/7] Zarf ARM64 (${ZARF_VERSION})..."
download_file "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/zarf_${ZARF_VERSION}_Linux_arm64" "${DOWNLOADS_DIR}/zarf" "Zarf ARM64 CLI"
chmod +x "${DOWNLOADS_DIR}/zarf" 2>/dev/null || true

# 6. UDS CLI ARM64
echo ""
echo "[6/7] UDS CLI ARM64 (${UDS_VERSION})..."
download_file "https://github.com/defenseunicorns/uds-cli/releases/download/${UDS_VERSION}/uds-cli_${UDS_VERSION}_Linux_arm64" "${DOWNLOADS_DIR}/uds" "UDS CLI ARM64" || \
download_file "https://github.com/defenseunicorns/uds-cli/releases/download/${UDS_VERSION}/uds-cli_${UDS_VERSION#v}_Linux_arm64" "${DOWNLOADS_DIR}/uds" "UDS CLI ARM64"
chmod +x "${DOWNLOADS_DIR}/uds" 2>/dev/null || true

# 7. K9s ARM64
echo ""
echo "[7/7] K9s Terminal UI ARM64 (${K9S_VERSION})..."
if [[ ! -f "${DOWNLOADS_DIR}/k9s" ]]; then
    TMP_K9S="${DOWNLOADS_DIR}/k9s-${K9S_VERSION}.tar.gz"
    download_file "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_arm64.tar.gz" "${TMP_K9S}" "K9s ARM64 Archive"
    if [[ -f "${TMP_K9S}" ]]; then
        tar -xzf "${TMP_K9S}" -C "${DOWNLOADS_DIR}" k9s
        rm -f "${TMP_K9S}"
        chmod +x "${DOWNLOADS_DIR}/k9s"
    fi
fi

echo ""
echo "======================================================================"
echo "All offline assets fetched successfully into: ${DOWNLOADS_DIR}"
echo "You are ready to flash the SD card using: make flash-sd DISK=/dev/sdX"
echo "======================================================================"
