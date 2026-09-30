#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: 00-configure.sh
# Purpose: Interactive NIST SP 800-53 / 800-63B compliant configuration wizard
#          (Generates SHA-512 password hashes, manages SSH keys, writes env file)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/env"
ENV_EXAMPLE="${ROOT_DIR}/env.example"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  Orange Pi Air-Gapped Appliance Configuration Wizard${NC}"
echo -e "${BLUE}  NIST SP 800-53 (Rev. 5) & NIST SP 800-63B Security Hardening${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Load existing defaults if env exists
EXISTING_USER=""
EXISTING_HOST=""
EXISTING_IP=""
EXISTING_BOARD=""

if [[ -f "${ENV_FILE}" ]]; then
    echo -e "${GREEN}Found existing env configuration file.${NC}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    EXISTING_USER="${DEFAULT_USER:-}"
    EXISTING_HOST="${HOSTNAME:-}"
    EXISTING_IP="${TARGET_IP:-}"
    EXISTING_BOARD="${BOARD_MODEL:-}"
elif [[ -f "${ENV_EXAMPLE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_EXAMPLE}"
    EXISTING_USER="${DEFAULT_USER:-bjarrett}"
    EXISTING_HOST="${HOSTNAME:-orangepi5pro}"
    EXISTING_IP="${TARGET_IP:-192.168.42.100}"
    EXISTING_BOARD="${BOARD_MODEL:-orangepi5-pro}"
fi

CURRENT_USER="${EXISTING_USER:-${USER:-bjarrett}}"
CURRENT_HOST="${EXISTING_HOST:-orangepi5pro}"
CURRENT_IP="${EXISTING_IP:-192.168.42.100}"
CURRENT_BOARD="${EXISTING_BOARD:-orangepi5-pro}"

# 2. Prompt for Administrator Username
echo ""
echo -e "${YELLOW}[1/4] Administrator Account Configuration (NIST AC-2 / AC-6)${NC}"
read -rp "Enter appliance administrator username [${CURRENT_USER}]: " INPUT_USER
ADMIN_USER="${INPUT_USER:-${CURRENT_USER}}"
if [[ ! "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo -e "${RED}Error: Invalid username '${ADMIN_USER}'. Must follow standard POSIX naming.${NC}"
    exit 1
fi
echo -e "  -> Administrator username set to: ${GREEN}${ADMIN_USER}${NC}"

# 3. Prompt for Administrator Password with NIST 800-63B Validation & SHA-512 Hashing
echo ""
echo -e "${YELLOW}[2/4] Password & Cryptographic Hashing (NIST IA-5 / NIST 800-63B)${NC}"
echo -e "  NIST Guidelines: Passwords should be $\ge 15$ characters for administrative accounts."
echo -e "  Plaintext passwords will NEVER be saved to disk. Only salted SHA-512 hashes are stored."

PASSWORD_MATCH=false
ADMIN_PASS_HASH=""

while [[ "${PASSWORD_MATCH}" == "false" ]]; do
    echo ""
    read -rsp "Enter administrator password (hidden): " PASS1
    echo ""
    
    if [[ ${#PASS1} -lt 15 ]]; then
        echo -e "${YELLOW}Warning: Password length is ${#PASS1} characters (NIST recommends $\ge 15$).${NC}"
        read -rp "Do you want to proceed with this password length? [y/N]: " PROCEED_SHORT
        if [[ ! "${PROCEED_SHORT}" =~ ^[yY](es)?$ ]]; then
            continue
        fi
    fi
    
    read -rsp "Confirm administrator password (hidden): " PASS2
    echo ""
    
    if [[ "${PASS1}" != "${PASS2}" ]]; then
        echo -e "${RED}Error: Passwords do not match. Please try again.${NC}"
    else
        PASSWORD_MATCH=true
        # Generate salted SHA-512 crypt hash
        ADMIN_PASS_HASH=$(openssl passwd -6 "${PASS1}")
        # Clear plaintext variables immediately
        unset PASS1 PASS2
        echo -e "  -> ${GREEN}Password successfully verified and hashed with SHA-512 (crypt-sha512).${NC}"
    fi
done

# 4. SSH Public Key Verification & Auto-Generation (NIST IA-2 / AC-17)
echo ""
echo -e "${YELLOW}[3/4] SSH Public Key Authentication (NIST IA-2(1) / IA-2(2))${NC}"
SSH_KEY_FOUND=false
SSH_KEY_PATH=""

# Check for existing standard keys
for KEY_CANDIDATE in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub" "${HOME}/.ssh/id_ed25519_orangepi.pub"; do
    if [[ -f "${KEY_CANDIDATE}" ]]; then
        SSH_KEY_FOUND=true
        SSH_KEY_PATH="${KEY_CANDIDATE}"
        break
    fi
done

if [[ "${SSH_KEY_FOUND}" == "true" ]]; then
    echo -e "  -> Found existing workstation SSH key: ${GREEN}${SSH_KEY_PATH}${NC}"
else
    echo -e "${YELLOW}  No standard SSH public key found in ~/.ssh/.${NC}"
    read -rp "  Generate a new dedicated Ed25519 SSH keypair (~/.ssh/id_ed25519_orangepi)? [Y/n]: " GEN_KEY
    if [[ "${GEN_KEY}" =~ ^[nN](o)?$ ]]; then
        echo -e "${RED}Warning: Passwordless SSH will not function without a valid public key.${NC}"
    else
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"
        ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519_orangepi" -N "" -C "${ADMIN_USER}@${CURRENT_HOST}"
        chmod 600 "${HOME}/.ssh/id_ed25519_orangepi"
        chmod 644 "${HOME}/.ssh/id_ed25519_orangepi.pub"
        echo -e "  -> ${GREEN}Generated dedicated Ed25519 keypair at ~/.ssh/id_ed25519_orangepi${NC}"
    fi
fi

# 5. Network & Appliance Defaults
echo ""
echo -e "${YELLOW}[4/4] Network & Hardware Settings (NIST CM-6 / SC-8)${NC}"
read -rp "Enter target Orange Pi hostname [${CURRENT_HOST}]: " INPUT_HOST
APPLIANCE_HOST="${INPUT_HOST:-${CURRENT_HOST}}"

read -rp "Enter target static maintenance IP [${CURRENT_IP}]: " INPUT_IP
APPLIANCE_IP="${INPUT_IP:-${CURRENT_IP}}"

read -rp "Enter board model (orangepi5-pro, orangepi5, orangepi3-lts) [${CURRENT_BOARD}]: " INPUT_BOARD
APPLIANCE_BOARD="${INPUT_BOARD:-${CURRENT_BOARD}}"

# 6. Deterministic Appliance SSH Host Key & Known-Hosts Pinning (NIST SC-8 / IA-3 / SC-28)
echo ""
echo -e "${YELLOW}[5/5] Deterministic Appliance SSH Host Key & Known-Hosts Pinning (NIST SC-8 / IA-3)${NC}"
mkdir -p "${ROOT_DIR}/keys"
HOST_KEY_FILE="${ROOT_DIR}/keys/ssh_host_ed25519_key"
if [[ ! -f "${HOST_KEY_FILE}" ]]; then
    echo -e "  -> Generating deterministic Ed25519 appliance host key..."
    ssh-keygen -t ed25519 -f "${HOST_KEY_FILE}" -N "" -C "host@${APPLIANCE_HOST}" >/dev/null
    chmod 600 "${HOST_KEY_FILE}"
    chmod 644 "${HOST_KEY_FILE}.pub"
    echo -e "  -> ${GREEN}Appliance host key generated at keys/ssh_host_ed25519_key${NC}"
else
    echo -e "  -> ${GREEN}Found existing appliance host key at keys/ssh_host_ed25519_key${NC}"
fi

PUB_KEY_CONTENT=$(awk '{print $1, $2}' "${HOST_KEY_FILE}.pub")
echo "${APPLIANCE_IP} ${PUB_KEY_CONTENT}" > "${ROOT_DIR}/known_hosts"
chmod 600 "${ROOT_DIR}/known_hosts"
echo -e "  -> ${GREEN}Pinned ${APPLIANCE_IP} host key to ./known_hosts (StrictHostKeyChecking=yes ready)${NC}"

# 7. Write to env with strict 0600 permissions
cat << EOF > "${ENV_FILE}"
# ==============================================================================
# Orange Pi Air-Gapped Appliance Configuration
# Generated by: make config / scripts/00-configure.sh
# NIST SP 800-53 / NIST SP 800-63B Compliant (Zero Plaintext Secrets)
# ==============================================================================

# Hardware Target
BOARD_MODEL="${APPLIANCE_BOARD}"
HOSTNAME="${APPLIANCE_HOST}"

# Deterministic User Management (NIST AC-2 / AC-6)
DEFAULT_USER="${ADMIN_USER}"
DEFAULT_PASSWORD_HASH='${ADMIN_PASS_HASH}'

# Deterministic Air-Gap Maintenance Networking (NIST SC-8 / IA-5)
TARGET_IP="${APPLIANCE_IP}"
TARGET_SUBNET="255.255.255.0"
TARGET_PORT="22"

# Storage Device (Populated by make select-sd)
SD_DISK="${SD_DISK:-}"

# Offline Tool Versions
K3S_VERSION="${K3S_VERSION:-v1.30.4+k3s1}"
UDS_CLI_VERSION="${UDS_CLI_VERSION:-v0.19.0}"
ZARF_CLI_VERSION="${ZARF_CLI_VERSION:-v0.38.3}"
HELM_VERSION="${HELM_VERSION:-v3.15.4}"
K9S_VERSION="${K9S_VERSION:-v0.32.5}"
EOF

chmod 600 "${ENV_FILE}"

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  Configuration successfully saved to: ${ENV_FILE}${NC}"
echo -e "${GREEN}  File permissions set to: -rw------- (0600)${NC}"
echo -e "${GREEN}  Plaintext passwords: None (Stored as salted SHA-512 crypt hash)${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e "Next steps:"
echo -e "  1. Run '${BLUE}make fetch-assets${NC}' to download platform assets"
echo -e "  2. Run '${BLUE}make select-sd${NC}' to select target SD card"
echo -e "  3. Run '${BLUE}make flash-sd${NC}' to flash and stage appliance"
echo -e "  4. Run '${BLUE}make bootstrap${NC}' to commission live cluster"
echo -e "${GREEN}======================================================================${NC}"
