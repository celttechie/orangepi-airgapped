#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 01-setup-laptop-net.sh
# Purpose: Configure laptop Ethernet interface for direct connection to Orange Pi
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

IFACE="${1:-${LAPTOP_IFACE:-eth0}}"
IP="${LAPTOP_IP:-192.168.42.1}"
NETMASK="${LAPTOP_NETMASK:-255.255.255.0}"
CIDR="24"

echo "======================================================================"
echo "Configuring Laptop Network Interface for Direct Connection"
echo "Interface: ${IFACE}"
echo "IP:        ${IP}/${CIDR}"
echo "======================================================================"

# Check if interface exists
if ! ip link show "${IFACE}" >/dev/null 2>&1; then
    echo "Error: Interface '${IFACE}' not found."
    echo "Available interfaces:"
    ip -br link
    exit 1
fi

echo "[1/3] Bringing up interface ${IFACE}..."
sudo ip link set "${IFACE}" up

echo "[2/3] Assigning static IP ${IP}/${CIDR}..."
# Remove existing IP on subnet if present to avoid conflicts
sudo ip addr flush dev "${IFACE}" || true
sudo ip addr add "${IP}/${CIDR}" dev "${IFACE}"

echo "[3/3] Updating dnsmasq.conf with interface ${IFACE}..."
sed -i "s/^interface=.*/interface=${IFACE}/" "${ROOT_DIR}/config/dnsmasq.conf"

echo ""
echo "Interface ${IFACE} successfully configured with ${IP}/${CIDR}."
ip -br addr show "${IFACE}"
echo "======================================================================"
