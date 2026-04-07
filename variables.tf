# =====================================================
# Variables — Customize these for your deployment
# =====================================================

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "CloudLensGwLB-rg"
}

variable "vnet_address_space" {
  description = "Address space for the VNet"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "admin_username" {
  description = "Admin username for web servers and tool VM"
  type        = string
  default     = "azureuser"
}

variable "admin_password" {
  description = "Admin password for web servers and tool VM"
  type        = string
  sensitive   = true
}

variable "vpb_admin_username" {
  description = "OS-level admin username for vPB VMs"
  type        = string
  default     = "vpb"
}

variable "vpb_admin_password" {
  description = "OS-level admin password for vPB VMs"
  type        = string
  sensitive   = true
}

variable "vpb_cli_password" {
  description = "vPB CLI password (default: ixia)"
  type        = string
  sensitive   = true
  default     = "ixia"
}

variable "vpb_installer_path" {
  description = "Local path to vpb-3.14.0-30-install-package.sh"
  type        = string
}

variable "vlm_vhd_path" {
  description = "Local path to CloudLens-vLM-1.7.vhd"
  type        = string
}

variable "vpb_vm_size" {
  description = "VM size for vPB instances (minimum 8 vCPU for DPDK)"
  type        = string
  default     = "Standard_D8_v5"
}

variable "web_vm_size" {
  description = "VM size for web server instances"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "tool_vm_size" {
  description = "VM size for the tool/monitoring VM"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "vlm_vm_size" {
  description = "VM size for the Virtual License Manager"
  type        = string
  default     = "Standard_D2s_v3"
}
