.PHONY: help fetch-assets select-sd detect-sd flash-sd setup-net handoff status clean

# Default shell
SHELL := /bin/bash

# Configuration file
ENV_FILE := env
ifeq ($(wildcard $(ENV_FILE)),)
    ENV_FILE := env.example
endif

help: ## Show this help message
	@echo "Orange Pi Air-Gapped Provisioner (orangepi-airgapped)"
	@echo "======================================================================"
	@echo "Standalone Air-Gapped Armbian Desktop + K3s + UDS Toolchain"
	@echo "======================================================================"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

fetch-assets: ## Download Armbian Desktop image, K3s ARM64 binaries & airgap images, and CLI tools
	@chmod +x scripts/*.sh
	@scripts/01-fetch-assets.sh

select-sd: ## Interactively identify, confirm, and save target SD/NVMe storage device to env
	@chmod +x scripts/*.sh
	@scripts/detect-sd-device.sh

detect-sd: select-sd ## Alias for select-sd

flash-sd: ## Flash Armbian and stage platform assets to SD/NVMe (Uses SD_DISK from env or DISK=/dev/sdX)
	@chmod +x scripts/*.sh
	@scripts/02-flash-and-stage-sd.sh $(DISK)

setup-net: ## [Optional] Configure laptop Ethernet interface for direct connection (e.g. make setup-net IFACE=eth0)
	@chmod +x scripts/*.sh
	@scripts/01-setup-laptop-net.sh $(IFACE)

handoff: ## Configure uds-platform-prep directory for ARM64 deployment
	@chmod +x scripts/*.sh
	@scripts/03-handoff-uds.sh

status: ## Verify cluster state via local kubeconfig if tethered or remote
	@export KUBECONFIG=$${KUBECONFIG:-./kubeconfig}; kubectl get nodes -o wide || echo "Cluster not responding or kubeconfig missing. Ensure Orange Pi is booted."

clean: ## Clean up temporary staging mounts and build output
	@rm -rf _out /tmp/orangepi_rootfs.*
