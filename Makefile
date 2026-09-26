.PHONY: help setup-net fetch-assets flash-sd start-server stop-server start-pxe stop-pxe bootstrap handoff status clean spi-info

# Default shell
SHELL := /bin/bash

# Configuration file
ENV_FILE := env
ifeq ($(wildcard $(ENV_FILE)),)
    ENV_FILE := env.example
endif

help: ## Show this help message
	@echo "Orange Pi Air-Gapped Provisioner (orangepi-airgapped)"
	@echo "======================================================"
	@echo "Workflow 1: Direct Storage Flash (SD / NVMe)"
	@echo "Workflow 2: True Network / PXE Boot (SPI Flash Netboot)"
	@echo "======================================================"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup-net: ## Configure laptop Ethernet interface with static IP (e.g. make setup-net IFACE=eth0)
	@chmod +x scripts/*.sh
	@scripts/01-setup-laptop-net.sh $(IFACE)

fetch-assets: ## Download Talos ARM64 kernel, initramfs, and raw images
	@chmod +x scripts/*.sh
	@scripts/02-fetch-talos-assets.sh

flash-sd: ## [Option 1] Flash Talos image to MicroSD card (Usage: make flash-sd DISK=/dev/sdX)
	@chmod +x scripts/*.sh
	@scripts/03-create-sd-bootstrap.sh $(DISK)

start-pxe: ## [Option 2] Start local DHCP/TFTP/HTTP netboot docker containers
	@docker compose up -d
	@echo "PXE / Netboot server running on laptop."

stop-pxe: ## [Option 2] Stop local DHCP/TFTP/HTTP netboot docker containers
	@docker compose down

start-server: start-pxe ## Alias for start-pxe

stop-server: stop-pxe ## Alias for stop-pxe

spi-info: ## [Option 2] Show instructions for one-time SPI NOR Flash programming for PXE
	@echo "======================================================================"
	@echo "Orange Pi 5 / 5 Pro SPI NOR Flash Netboot Setup"
	@echo "======================================================================"
	@echo "To enable true diskless PXE booting on Orange Pi 5:"
	@echo "1. Boot standard Armbian/Orange Pi OS from an SD card once."
	@echo "2. Run: sudo orangepi-config -> System -> Install -> Install to SPI."
	@echo "   (or: sudo dd if=/usr/lib/linux-u-boot-.../u-boot-rockchip-spi.bin of=/dev/mtdblock0)"
	@echo "3. Power off, remove SD card."
	@echo "4. The board will now boot U-Boot from SPI and PXE boot over Ethernet."
	@echo "======================================================================"

bootstrap: ## Apply Talos machine config to Orange Pi and retrieve kubeconfig
	@chmod +x scripts/*.sh
	@scripts/04-apply-talos-config.sh

handoff: ## Link kubeconfig and configure uds-platform-prep for ARM64
	@chmod +x scripts/*.sh
	@scripts/05-handoff-uds.sh

status: ## Check connection and Kubernetes cluster state
	@export KUBECONFIG=./kubeconfig; kubectl get nodes -o wide || echo "Cluster not yet responding or kubeconfig missing."

clean: ## Remove generated secrets, boot assets cache, and configurations
	@rm -rf _out kubeconfig
