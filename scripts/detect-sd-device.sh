#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: detect-sd-device.sh
# Purpose: Interactive detection and selection of target SD/NVMe storage device
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/env"
ENV_EXAMPLE="${ROOT_DIR}/env.example"

echo "======================================================================"
echo "MicroSD / Storage Device Detection"
echo "======================================================================"

# Ensure env file exists
if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${ENV_EXAMPLE}" ]]; then
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    else
        touch "${ENV_FILE}"
    fi
fi

# Gather available physical disk devices (exclude zram, loop, ram)
mapfile -t ALL_DISKS < <(lsblk -d -p -n -o NAME,SIZE,TRAN,MODEL,RM,TYPE | grep -E "disk" | grep -v -E "zram|loop" || true)

if [[ ${#ALL_DISKS[@]} -eq 0 ]]; then
    echo "Error: No disk block devices found."
    exit 1
fi

echo "Available physical block devices on this system:"
echo ""
printf "  %-4s %-16s %-8s %-6s %-30s %s\n" "NUM" "DEVICE" "SIZE" "TRAN" "MODEL" "FLAGS"
printf "  %-4s %-16s %-8s %-6s %-30s %s\n" "---" "------" "----" "----" "-----" "-----"

CANDIDATES=()
INDEX=1
DEFAULT_INDEX=""

for LINE in "${ALL_DISKS[@]}"; do
    DEV_NAME=$(echo "${LINE}" | awk '{print $1}')
    DEV_SIZE=$(echo "${LINE}" | awk '{print $2}')
    DEV_TRAN=$(echo "${LINE}" | awk '{print $3}')
    DEV_RM=$(echo "${LINE}" | awk '{print $(NF-1)}')
    DEV_MODEL=$(echo "${LINE}" | awk '{for(i=4;i<=NF-2;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
    if [[ -z "${DEV_MODEL}" ]]; then DEV_MODEL="Generic/Unknown"; fi

    FLAGS=""
    # Check if removable USB or MMC device
    if [[ "${DEV_RM}" == "1" || "${DEV_TRAN}" == "usb" || "${DEV_NAME}" =~ mmcblk ]]; then
        FLAGS="[REMOVABLE / SD-CARD CANDIDATE]"
        if [[ -z "${DEFAULT_INDEX}" ]]; then
            DEFAULT_INDEX="${INDEX}"
        fi
    fi

    printf "  [%d]  %-16s %-8s %-6s %-30s %s\n" "${INDEX}" "${DEV_NAME}" "${DEV_SIZE}" "${DEV_TRAN}" "${DEV_MODEL}" "${FLAGS}"
    CANDIDATES+=("${DEV_NAME}")
    ((INDEX++))
done

echo ""
if [[ -n "${DEFAULT_INDEX}" ]]; then
    PROMPT_DEFAULT=" [default: ${DEFAULT_INDEX} -> ${CANDIDATES[$((DEFAULT_INDEX-1))]}]"
else
    PROMPT_DEFAULT=""
fi

read -p "Select device number (1-${#CANDIDATES[@]}) or enter full path (/dev/sdX)${PROMPT_DEFAULT}: " -r CHOICE

CHOICE="${CHOICE:-${DEFAULT_INDEX}}"

if [[ "${CHOICE}" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#CANDIDATES[@]} )); then
    SELECTED_DEVICE="${CANDIDATES[$((CHOICE-1))]}"
elif [[ -b "${CHOICE}" ]]; then
    SELECTED_DEVICE="${CHOICE}"
else
    echo "Invalid selection: '${CHOICE}'"
    exit 1
fi

# Fetch detailed info on selected device
SEL_SIZE=$(lsblk -d -n -o SIZE "${SELECTED_DEVICE}" 2>/dev/null || echo "Unknown")
SEL_MODEL=$(lsblk -d -n -o MODEL "${SELECTED_DEVICE}" 2>/dev/null || echo "Unknown")
SEL_TRAN=$(lsblk -d -n -o TRAN "${SELECTED_DEVICE}" 2>/dev/null || echo "Unknown")

echo ""
echo "======================================================================"
echo "Explicit Choice Verification:"
echo "  Target Device Path: ${SELECTED_DEVICE}"
echo "  Device Capacity:    ${SEL_SIZE}"
echo "  Device Model:       ${SEL_MODEL}"
echo "  Transport / Bus:    ${SEL_TRAN}"
echo "  Current Partitions:"
lsblk -p -o NAME,SIZE,FSTYPE,MOUNTPOINTS "${SELECTED_DEVICE}" | sed 's/^/    /'
echo "======================================================================"

read -p "Confirm saving '${SELECTED_DEVICE}' as default DISK for 'make flash-sd'? [y/N]: " -r CONFIRM

if [[ "${CONFIRM}" =~ ^[Yy]$ || "${CONFIRM}" =~ ^[Yy][Ee][Ss]$ ]]; then
    # Update or add SD_DISK in env file
    if grep -q "^SD_DISK=" "${ENV_FILE}"; then
        sed -i "s|^SD_DISK=.*|SD_DISK=\"${SELECTED_DEVICE}\"|" "${ENV_FILE}"
    else
        echo "SD_DISK=\"${SELECTED_DEVICE}\"" >> "${ENV_FILE}"
    fi

    echo ""
    echo "[SUCCESS] Default target storage set to: ${SELECTED_DEVICE} in '${ENV_FILE}'"
    echo "You can now run: make flash-sd"
    echo "(It will automatically target ${SELECTED_DEVICE} unless overridden with DISK=/dev/...)"
    echo "======================================================================"
else
    echo "Selection not saved."
    exit 1
fi
