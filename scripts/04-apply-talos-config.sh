#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 04-apply-talos-config.sh
# Purpose: Generate Talos machine configs, apply to Orange Pi, bootstrap cluster
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${ROOT_DIR}/_out"

# Load configuration
if [[ -f "${ROOT_DIR}/env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env"
elif [[ -f "${ROOT_DIR}/env.example" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env.example"
fi

TARGET_IP="${TARGET_IP:-192.168.42.100}"
CLUSTER_NAME="${CLUSTER_NAME:-opi-uds-edge}"
CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:-https://${TARGET_IP}:6443}"
TALOS_VERSION="${TALOS_VERSION:-v1.7.5}"
INSTALL_DISK="${INSTALL_DISK:-/dev/mmcblk0}"

mkdir -p "${OUT_DIR}" "${ROOT_DIR}/http"

echo "======================================================================"
echo "Talos Node Bootstrapping & Machine Configuration"
echo "Target Node:     ${TARGET_IP}"
echo "Cluster Name:    ${CLUSTER_NAME}"
echo "Endpoint:        ${CLUSTER_ENDPOINT}"
echo "Install Disk:    ${INSTALL_DISK}"
echo "======================================================================"

# 1. Generate secrets if not existing
if [[ ! -f "${OUT_DIR}/secrets.yaml" ]]; then
    echo "[1/5] Generating fresh Talos cluster secrets..."
    talosctl gen secrets -o "${OUT_DIR}/secrets.yaml"
fi

# 2. Create MachineConfig patch for Single-Node / Edge operation
cat << EOF > "${OUT_DIR}/single-node-patch.yaml"
machine:
  install:
    disk: ${INSTALL_DISK}
    wipe: false
  network:
    hostname: opi-node-01
    interfaces:
      - interface: eth0
        dhcp: true
  nodeLabels:
    node-role.kubernetes.io/edge: "true"
    topology.kubernetes.io/zone: "local-edge"
cluster:
  allowSchedulingOnControlPlanes: true
  apiServer:
    admissionControl: []
EOF

# 3. Generate Controlplane & Worker configurations
echo "[2/5] Generating machine configuration for ${CLUSTER_NAME}..."
talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
    --with-secrets "${OUT_DIR}/secrets.yaml" \
    --config-patch @"${OUT_DIR}/single-node-patch.yaml" \
    --output-dir "${OUT_DIR}" \
    --force

# Copy controlplane config to HTTP root for netboot auto-discovery
cp "${OUT_DIR}/controlplane.yaml" "${ROOT_DIR}/http/machineconfig.yaml"

echo "[3/5] Waiting for Talos API on ${TARGET_IP}:50000..."
MAX_ATTEMPTS=30
ATTEMPT=1
until nc -z -w 2 "${TARGET_IP}" 50000 >/dev/null 2>&1; do
    if (( ATTEMPT > MAX_ATTEMPTS )); then
        echo "Error: Timed out waiting for Talos API on ${TARGET_IP}:50000."
        echo "Ensure Orange Pi is powered on and connected to your laptop."
        exit 1
    fi
    echo "  Attempt ${ATTEMPT}/${MAX_ATTEMPTS}: waiting for node ${TARGET_IP}..."
    sleep 3
    ((ATTEMPT++))
done
echo "Talos node is reachable!"

# 4. Apply configuration to node
echo "[4/5] Applying machine configuration to ${TARGET_IP}..."
talosctl apply-config \
    --insecure \
    --nodes "${TARGET_IP}" \
    --endpoints "${TARGET_IP}" \
    --file "${OUT_DIR}/controlplane.yaml"

echo "Sleeping 10s for Talos services to initialize..."
sleep 10

# 5. Bootstrap cluster etcd
echo "[5/5] Bootstrapping Kubernetes etcd cluster..."
talosctl bootstrap \
    --nodes "${TARGET_IP}" \
    --endpoints "${TARGET_IP}" \
    --talosconfig "${OUT_DIR}/talosconfig" || true

echo "Retrieving kubeconfig..."
talosctl kubeconfig "${ROOT_DIR}/kubeconfig" \
    --nodes "${TARGET_IP}" \
    --endpoints "${TARGET_IP}" \
    --talosconfig "${OUT_DIR}/talosconfig" \
    --force

echo ""
echo "======================================================================"
echo "Talos Cluster Bootstrap Complete!"
echo "Kubeconfig saved to: ${ROOT_DIR}/kubeconfig"
echo "Talosconfig saved to: ${OUT_DIR}/talosconfig"
echo "======================================================================"
