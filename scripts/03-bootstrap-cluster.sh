#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 03-bootstrap-cluster.sh
# Purpose: Commission and bootstrap the air-gapped K3s cluster from laptop
#          (Syncs exact real-world clock, starts K3s, and fetches kubeconfig)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment configuration
if [[ -f "${ROOT_DIR}/env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env"
elif [[ -f "${ROOT_DIR}/env.example" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/env.example"
fi

TARGET_IP="${TARGET_IP:-192.168.42.100}"
TARGET_USER="${DEFAULT_USER:-bjarrett}"
TARGET_PORT="${TARGET_PORT:-22}"
KNOWN_HOSTS_FILE="${ROOT_DIR}/known_hosts"
HOST_KEY_PUB="${ROOT_DIR}/keys/ssh_host_ed25519_key.pub"

# Ensure local known_hosts exists with the deterministic host key
if [[ ! -f "${KNOWN_HOSTS_FILE}" ]] && [[ -f "${HOST_KEY_PUB}" ]]; then
    PUB_KEY_CONTENT=$(awk '{print $1, $2}' "${HOST_KEY_PUB}")
    echo "${TARGET_IP} ${PUB_KEY_CONTENT}" > "${KNOWN_HOSTS_FILE}"
    chmod 600 "${KNOWN_HOSTS_FILE}"
fi

if [[ ! -f "${KNOWN_HOSTS_FILE}" ]]; then
    echo "Error: Deterministic known_hosts file not found at ${KNOWN_HOSTS_FILE}." >&2
    echo "Please run 'make flash-sd' or 'make config' to generate and stage host keys." >&2
    exit 1
fi

SSH_OPTS=(-o "StrictHostKeyChecking=yes" -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}" -o "ConnectTimeout=5" -o "LogLevel=ERROR")
KUBECONFIG_OUT="${ROOT_DIR}/kubeconfig"

echo "======================================================================"
echo "  Air-Gapped Orange Pi K3s Commissioning & Cluster Bootstrap"
echo "  Target Host: ${TARGET_USER}@${TARGET_IP}:${TARGET_PORT}"
echo "  SSH Security: StrictHostKeyChecking=yes (Pinned to ./known_hosts)"
echo "======================================================================"

# Step 1: Wait for SSH Reachability
echo "[1/5] Waiting for Orange Pi to become reachable over SSH..."
MAX_ATTEMPTS=60
ATTEMPT=0
while ! ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" "echo reachable" >/dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    if [[ ${ATTEMPT} -ge ${MAX_ATTEMPTS} ]]; then
        echo "Error: Timed out waiting for ${TARGET_USER}@${TARGET_IP} after ${MAX_ATTEMPTS} attempts."
        echo "Please ensure the Orange Pi is powered on and Ethernet cable is connected to your laptop."
        exit 1
    fi
    echo "  -> Attempt ${ATTEMPT}/${MAX_ATTEMPTS}: waiting for SSH..."
    sleep 3
done
echo "  -> Success: SSH connection established with ${TARGET_USER}@${TARGET_IP}."

# Step 2: Synchronize System Clock to Workstation UTC
echo "[2/5] Synchronizing Orange Pi clock to workstation timestamp..."
HOST_UTC=$(date -u +"%Y-%m-%d %H:%M:%S")
ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" "sudo date -u -s '${HOST_UTC}' && echo '${HOST_UTC}' | sudo tee /etc/fake-hwclock.data >/dev/null && date -u"
echo "  -> Clock synchronized to: ${HOST_UTC} UTC"

# Step 3: Start and Enable K3s Service
echo "[3/5] Starting and enabling K3s Kubernetes service..."
ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" '
    sudo systemctl daemon-reload
    sudo systemctl enable --now k3s.service
'

# Step 4: Fetch and Configure Kubeconfig on Laptop
echo "[4/5] Fetching Kubeconfig from Orange Pi..."
MAX_KUBE_WAIT=30
KUBE_ATTEMPT=0
while ! ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" "test -f /etc/rancher/k3s/k3s.yaml" >/dev/null 2>&1; do
    KUBE_ATTEMPT=$((KUBE_ATTEMPT + 1))
    if [[ ${KUBE_ATTEMPT} -ge ${MAX_KUBE_WAIT} ]]; then
        echo "Error: Timed out waiting for /etc/rancher/k3s/k3s.yaml on Orange Pi."
        exit 1
    fi
    echo "  -> Waiting for K3s to generate /etc/rancher/k3s/k3s.yaml (${KUBE_ATTEMPT}/${MAX_KUBE_WAIT})..."
    sleep 2
done

# Pull and adapt kubeconfig for workstation access
ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_IP}" 'sudo cat /etc/rancher/k3s/k3s.yaml' | \
    sed "s/127.0.0.1/${TARGET_IP}/g" > "${KUBECONFIG_OUT}"
chmod 600 "${KUBECONFIG_OUT}"

# Also sync to default ~/.kube/config if desired
mkdir -p "${HOME}/.kube"
cp "${KUBECONFIG_OUT}" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
echo "  -> Kubeconfig saved to: ${KUBECONFIG_OUT} and ${HOME}/.kube/config"

# Step 5: Verify Cluster Health
echo "[5/5] Verifying Kubernetes cluster readiness..."
echo "  -> Note: Initial cold first-boot extracts ~1.5 GB of offline container images onto SD storage."
export KUBECONFIG="${KUBECONFIG_OUT}"

MAX_READY_WAIT=180
SLEEP_WAIT=5
READY_ATTEMPT=0
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    READY_ATTEMPT=$((READY_ATTEMPT + 1))
    if [[ ${READY_ATTEMPT} -ge ${MAX_READY_WAIT} ]]; then
        echo "Warning: Cluster nodes did not report Ready within $((MAX_READY_WAIT * SLEEP_WAIT))s. Current state:"
        kubectl get nodes -o wide || true
        break
    fi
    echo "  -> Waiting for node to report Ready (${READY_ATTEMPT}/${MAX_READY_WAIT})..."
    sleep ${SLEEP_WAIT}
done

# Wait for core networking & DNS to reach Ready status
echo "  -> Verifying CoreDNS pod status..."
kubectl wait --namespace=kube-system --for=condition=Ready pod -l k8s-app=kube-dns --timeout=120s 2>/dev/null || true

echo ""
echo "======================================================================"
echo "  Kubernetes Cluster Commissioning Complete!"
echo "======================================================================"
kubectl get nodes -o wide
echo ""
kubectl get pods -A -o wide
echo ""
echo "Next step: Run 'make handoff' or deploy UDS bundles directly using:"
echo "  export KUBECONFIG=${KUBECONFIG_OUT}"
echo "======================================================================"
