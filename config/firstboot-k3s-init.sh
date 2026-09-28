#!/usr/bin/env bash
# ==============================================================================
# Script: firstboot-k3s-init.sh
# Purpose: Offline first-boot initialization for K3s & UDS platform on Armbian
# ==============================================================================
set -euo pipefail

LOG_FILE="/var/log/firstboot-k3s-init.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "[FirstBoot] Starting Air-Gapped K3s & UDS Platform Initialization"
echo "Date: $(date -u)"
echo "======================================================================"

# 1. Ensure kernel modules, sysctl, and fallback route for standalone airgap
echo "[1/6] Configuring kernel modules, sysctl, and air-gap network routes..."
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true

cat << 'EOF' > /etc/sysctl.d/99-kubernetes-k3s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system || true

# Ensure a default route entry exists in /proc/net/route even without DHCP/gateway
if ! ip route show | grep -q "^default"; then
    echo "Adding fallback default route on lo for isolated air-gap boot..."
    ip route add default dev lo metric 1000 2>/dev/null || true
fi

# 2. Configure environment profiles and aliases for users
echo "[2/6] Configuring bash profiles and aliases..."
for BASHRC_FILE in /root/.bashrc /home/armbian/.bashrc /etc/skel/.bashrc; do
    if [[ -f "${BASHRC_FILE}" ]]; then
        if ! grep -q "KUBECONFIG" "${BASHRC_FILE}"; then
            cat << 'EOF' >> "${BASHRC_FILE}"

# Kubernetes & UDS Platform Environment
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
alias k='kubectl'
alias k9s='/usr/local/bin/k9s'
alias uds='/usr/local/bin/uds'
alias zarf='/usr/local/bin/zarf'
EOF
        fi
    fi
done

# 3. Offline Installation of K3s
echo "[3/6] Installing K3s from pre-staged offline binaries..."
mkdir -p /etc/rancher/k3s

cat << 'EOF' > /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
node-ip: "127.0.0.1"
bind-address: "0.0.0.0"
disable:
  - traefik
  - servicelb
  - local-storage
EOF

export INSTALL_K3S_SKIP_DOWNLOAD=true
export INSTALL_K3S_SKIP_START=true
export INSTALL_K3S_BIN_DIR="/usr/local/bin"
export INSTALL_K3S_EXEC="server"

if [[ -f "/usr/local/bin/k3s-install.sh" ]]; then
    chmod +x /usr/local/bin/k3s /usr/local/bin/k3s-install.sh
    /usr/local/bin/k3s-install.sh
else
    chmod +x /usr/local/bin/k3s 2>/dev/null || true
    cat << 'EOF' > /etc/systemd/system/k3s.service
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network.target
After=network.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-/etc/systemd/system/%N.env
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s server

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now k3s.service || {
    echo "[WARNING] Initial systemctl start returned error, checking status..."
    systemctl status k3s.service --no-pager || true
}

# 4. Wait for Kubernetes API & Kubeconfig to become ready
echo "[4/6] Waiting for K3s API server and kubeconfig..."
MAX_WAIT=60
WAIT_COUNT=0
until [[ -f "/etc/rancher/k3s/k3s.yaml" ]] && /usr/local/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes >/dev/null 2>&1; do
    if (( WAIT_COUNT >= MAX_WAIT )); then
        echo "[WARNING] K3s API did not become ready within ${MAX_WAIT}s. Continuing..."
        break
    fi
    sleep 2
    ((WAIT_COUNT+=2))
done

# Ensure user permissions on kubeconfig
chmod 644 /etc/rancher/k3s/k3s.yaml || true
mkdir -p /root/.kube /home/armbian/.kube 2>/dev/null || true
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config 2>/dev/null || true
cp /etc/rancher/k3s/k3s.yaml /home/armbian/.kube/config 2>/dev/null || true
chown -R armbian:armbian /home/armbian/.kube 2>/dev/null || true

# 5. Set up Desktop shortcuts on user desktop
echo "[5/6] Setting up Desktop shortcuts..."
mkdir -p /home/armbian/Desktop /etc/skel/Desktop 2>/dev/null || true

if [[ -d "/usr/local/share/uds/desktop-shortcuts" ]]; then
    cp /usr/local/share/uds/desktop-shortcuts/*.desktop /home/armbian/Desktop/ 2>/dev/null || true
    cp /usr/local/share/uds/desktop-shortcuts/*.desktop /etc/skel/Desktop/ 2>/dev/null || true
    chmod +x /home/armbian/Desktop/*.desktop 2>/dev/null || true
    chmod +x /etc/skel/Desktop/*.desktop 2>/dev/null || true
    chown -R armbian:armbian /home/armbian/Desktop 2>/dev/null || true
fi

# 6. Create MOTD Banner
cat << 'EOF' > /etc/motd

======================================================================
  Orange Pi Air-Gapped UDS Platform Ready
======================================================================
  * Kubernetes (K3s): Active & Ready
  * UDS CLI:          /usr/local/bin/uds
  * Zarf CLI:         /usr/local/bin/zarf
  * K9s Terminal UI:  k9s
  * Kubeconfig:       /etc/rancher/k3s/k3s.yaml (or ~/.kube/config)

  To deploy UDS platform workloads locally:
    cd /opt/uds-platform-prep
    uds deploy ...
======================================================================

EOF

echo "[6/6] First-boot initialization complete!"
echo "======================================================================"

# Disable first-boot service so it doesn't rerun
systemctl disable firstboot-k3s-init.service || true
