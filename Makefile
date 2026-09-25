.PHONY: help setup-net fetch-assets flash-sd start-server stop-server bootstrap handoff status clean

# Default shell
SHELL := /bin/bash

# Configuration file
ENV_FILE := env
ifeq ($(wildcard $(ENV_FILE)),)
    ENV_FILE := env.example
endif

help: ## Show this help message
	@echo "Orange Pi Talos PXE & Direct-Attached Provisioner"
	@echo "=================================================="
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup-net: ## Configure laptop Ethernet interface with static IP (e.g. make setup-net IFACE=eth0)
	@chmod +x scripts/*.sh
	@scripts/01-setup-laptop-net.sh $(IFACE)

fetch-assets: ## Download Talos ARM64 kernel, initramfs, and raw images
	@chmod +x scripts/*.sh
	@scripts/02-fetch-talos-assets.sh

flash-sd: ## Flash Talos image to MicroSD card (Usage: make flash-sd DISK=/dev/sdX)
	@chmod +x scripts/*.sh
	@scripts/03-create-sd-bootstrap.sh $(DISK)

start-server: ## Start local DHCP/TFTP/HTTP netboot docker containers
	@docker compose up -d
	@echo "Boot server running on laptop."

stop-server: ## Stop local DHCP/TFTP/HTTP netboot docker containers
	@docker compose down

bootstrap: ## Apply Talos machine config to Orange Pi and retrieve kubeconfig
	@chmod +x scripts/*.sh
	@scripts/04-apply-talos-config.sh

handoff: ## Link kubeconfig and configure uds-platform-prep for ARM64
	@chmod +x scripts/*.sh
	@scripts/05-handoff-uds.sh

status: ## Check connection and Kubernetes cluster state
	@export KUBECONFIG=./kubeconfig; kubectl get nodes -o wide || echo "Cluster not yet responding or kubeconfig missing."

clean: ## Remove generated secrets and configurations
	@rm -rf _out kubeconfig
