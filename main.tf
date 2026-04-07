# =====================================================
# CloudLens vPB Active-Active HA — Azure GWLB
# =====================================================
# Deploys dual Virtual Packet Brokers behind an Azure
# Gateway Load Balancer for inline network visibility
# with cross-zone fault tolerance.
#
# Architecture:
#   Internet → Standard LB → GWLB → vPB (hairpin) → Web Servers
#   Both directions mirrored to Tool VM via VXLAN VNI 42
# =====================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=4.0, <5.0"
    }
  }
  required_version = ">=1.9.5"
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

# =====================================================
# Resource Group
# =====================================================
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# =====================================================
# Virtual Network & Subnets
# =====================================================
resource "azurerm_virtual_network" "vnet" {
  name                = "VNet"
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "consumer_subnet" {
  name                 = "ConsumerBackendNet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.0.0/24"]
}

resource "azurerm_subnet" "provider_subnet" {
  name                 = "ProviderBackendNet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_subnet" "management_subnet" {
  name                 = "CLManagementNet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.2.0/24"]
}

resource "azurerm_subnet" "tool_subnet" {
  name                 = "CLToolNet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.3.0/24"]
}

# =====================================================
# NAT Gateway (outbound internet for consumer subnet)
# =====================================================
resource "azurerm_public_ip" "nat_gateway_ip" {
  name                = "NATgatewayIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_nat_gateway" "nat_gateway" {
  name                    = "NATgateway"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  idle_timeout_in_minutes = 10
}

resource "azurerm_nat_gateway_public_ip_association" "nat_ip_association" {
  nat_gateway_id       = azurerm_nat_gateway.nat_gateway.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_ip.id
}

resource "azurerm_subnet_nat_gateway_association" "nat_subnet_association" {
  subnet_id      = azurerm_subnet.consumer_subnet.id
  nat_gateway_id = azurerm_nat_gateway.nat_gateway.id
  depends_on     = [azurerm_nat_gateway_public_ip_association.nat_ip_association]
}

# =====================================================
# Route Tables
# =====================================================
resource "azurerm_route_table" "tool_route_table" {
  name                = "ToolRouteTable"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_route" "tool_to_internet" {
  name                = "ToolToInternet"
  resource_group_name = azurerm_resource_group.rg.name
  route_table_name    = azurerm_route_table.tool_route_table.name
  address_prefix      = "0.0.0.0/0"
  next_hop_type       = "Internet"
}

resource "azurerm_subnet_route_table_association" "tool_subnet_route" {
  subnet_id      = azurerm_subnet.tool_subnet.id
  route_table_id = azurerm_route_table.tool_route_table.id
}

resource "azurerm_route_table" "web_route_table" {
  name                = "WebRouteTable"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_route_table" "vpb_route_table" {
  name                = "VPBRouteTable"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_route" "vpb_to_internet" {
  name                = "VPBToInternet"
  resource_group_name = azurerm_resource_group.rg.name
  route_table_name    = azurerm_route_table.vpb_route_table.name
  address_prefix      = "0.0.0.0/0"
  next_hop_type       = "Internet"
}

resource "azurerm_route" "vpb_to_web_servers" {
  name                   = "VPBToWebServers"
  resource_group_name    = azurerm_resource_group.rg.name
  route_table_name       = azurerm_route_table.vpb_route_table.name
  address_prefix         = "10.1.0.0/24"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.vpb_nic3.private_ip_address
}

resource "azurerm_route" "vxlan_route" {
  name                   = "VXLANRoute"
  resource_group_name    = azurerm_resource_group.rg.name
  route_table_name       = azurerm_route_table.vpb_route_table.name
  address_prefix         = "10.1.1.4/32"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "10.1.1.5"
}

resource "azurerm_subnet_route_table_association" "provider_subnet_route" {
  subnet_id      = azurerm_subnet.provider_subnet.id
  route_table_id = azurerm_route_table.vpb_route_table.id
  depends_on     = [azurerm_linux_virtual_machine.vpb_vm]
}

# =====================================================
# Network Security Groups
# =====================================================

# Consumer subnet NSG (web servers)
resource "azurerm_network_security_group" "nsg" {
  name                = "NSG"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "allow_vxlan" {
  name                       = "AllowVXLAN"
  priority                   = 150
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_ranges    = ["10800", "10801"]
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "allow_udp_4789_tool" {
  name                       = "AllowUDP4789Tool"
  priority                   = 203
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_range     = "4789"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "nsg_rule_http" {
  name                       = "NSGRuleHTTP"
  priority                   = 200
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "80"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "nsg_rule_ssh" {
  name                       = "NSGRuleSSH"
  priority                   = 201
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "22"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "tool_vm_outbound" {
  name                       = "AllowOutboundFromToolVM"
  priority                   = 202
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_subnet_network_security_group_association" "consumer_subnet_nsg" {
  subnet_id                 = azurerm_subnet.consumer_subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# vPB NSG (permissive — required for DPDK + VXLAN)
resource "azurerm_network_security_group" "vpb_nsg" {
  name                = "vPB-NSG"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "vpb_allow_all_in" {
  name                       = "myNSGRule-AllowAll"
  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "0.0.0.0/0"
  destination_address_prefix = "0.0.0.0/0"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vpb_nsg.name
}

resource "azurerm_network_security_rule" "vpb_allow_tcp_out" {
  name                       = "myNSGRule-AllowAll-TCP-Out"
  priority                   = 100
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "0.0.0.0/0"
  destination_address_prefix = "0.0.0.0/0"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vpb_nsg.name
}

resource "azurerm_network_security_rule" "vpb_allow_vxlann" {
  name                       = "AllowVXLANPorts"
  priority                   = 130
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_ranges    = ["10800", "10801"]
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vpb_nsg.name
}

resource "azurerm_network_security_rule" "vpb_allow_vxlan" {
  name                       = "AllowVXLANOutbound"
  priority                   = 140
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_ranges    = ["10800", "10801"]
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "vpb_allow_udp_4789_out" {
  name                       = "AllowUDP4789Out"
  priority                   = 160
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_range     = "4789"
  source_address_prefix      = "*"
  destination_address_prefix = azurerm_network_interface.tool_nic.private_ip_address
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vpb_nsg.name
}

resource "azurerm_network_security_rule" "http_web" {
  name                       = "AllowHTTPWebTraffic"
  priority                   = 110
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_ranges    = ["80"]
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vpb_nsg.name
}

# =====================================================
# Standard Load Balancer (public-facing)
# =====================================================
resource "azurerm_public_ip" "lb_public_ip" {
  name                = "PublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_lb" "lb" {
  name                = "LoadBalancer-to-GWLB"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  depends_on          = [azurerm_lb.gw_lb]

  frontend_ip_configuration {
    name                 = "FrontEnd"
    public_ip_address_id = azurerm_public_ip.lb_public_ip.id
    gateway_load_balancer_frontend_ip_configuration_id = azurerm_lb.gw_lb.frontend_ip_configuration[0].id
  }
}

resource "azurerm_lb_backend_address_pool" "backend_pool" {
  loadbalancer_id = azurerm_lb.lb.id
  name            = "GWLBBackendPool"
  depends_on      = [azurerm_lb.gw_lb]
}

resource "azurerm_lb_probe" "health_probe" {
  loadbalancer_id = azurerm_lb.lb.id
  name            = "HealthProbe"
  port            = 80
  protocol        = "Tcp"
}

resource "azurerm_lb_rule" "lb_to_gwlb" {
  loadbalancer_id                = azurerm_lb.lb.id
  name                           = "LBToGWLB"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "FrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
  probe_id                       = azurerm_lb_probe.health_probe.id
  idle_timeout_in_minutes        = 15
  enable_tcp_reset               = true
  disable_outbound_snat          = true
}

# SSH NAT rules for web server access
resource "azurerm_lb_nat_rule" "ssh_vm1" {
  resource_group_name            = azurerm_resource_group.rg.name
  loadbalancer_id                = azurerm_lb.lb.id
  name                           = "SSHWebServer1"
  protocol                       = "Tcp"
  frontend_port                  = 60001
  backend_port                   = 22
  frontend_ip_configuration_name = "FrontEnd"
}

resource "azurerm_lb_nat_rule" "ssh_vm2" {
  resource_group_name            = azurerm_resource_group.rg.name
  loadbalancer_id                = azurerm_lb.lb.id
  name                           = "SSHWebServer2"
  protocol                       = "Tcp"
  frontend_port                  = 60002
  backend_port                   = 22
  frontend_ip_configuration_name = "FrontEnd"
}

# =====================================================
# Gateway Load Balancer (VXLAN inline inspection)
# =====================================================
resource "azurerm_lb" "gw_lb" {
  name                = "GWLoadBalancer"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Gateway"

  frontend_ip_configuration {
    name                          = "FrontEnd"
    subnet_id                     = azurerm_subnet.provider_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "gw_backend_pool" {
  loadbalancer_id = azurerm_lb.gw_lb.id
  name            = "BackendPool"

  tunnel_interface {
    identifier = 900
    type       = "External"
    protocol   = "VXLAN"
    port       = 10800
  }

  tunnel_interface {
    identifier = 901
    type       = "Internal"
    protocol   = "VXLAN"
    port       = 10801
  }
}

resource "azurerm_lb_probe" "gw_health_probe" {
  loadbalancer_id     = azurerm_lb.gw_lb.id
  name                = "HealthProbe"
  port                = 80
  protocol            = "Tcp"
  interval_in_seconds = 5
}

resource "azurerm_lb_rule" "gw_lb_rule" {
  loadbalancer_id                = azurerm_lb.gw_lb.id
  name                           = "LBRule"
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "FrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.gw_backend_pool.id]
  probe_id                       = azurerm_lb_probe.gw_health_probe.id
}

# =====================================================
# Web Servers (consumer backend)
# =====================================================
locals {
  cloud_init_webserver = templatefile("${path.module}/cloud_init_webserver.tpl", {})
}

resource "azurerm_network_interface" "nic_vm1" {
  name                = "NicVM1"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.consumer_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_vm2" {
  name                = "NicVM2"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.consumer_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "nic_vm1_nsg" {
  network_interface_id      = azurerm_network_interface.nic_vm1.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_security_group_association" "nic_vm2_nsg" {
  network_interface_id      = azurerm_network_interface.nic_vm2.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_nat_rule_association" "nic_vm1_nat" {
  network_interface_id  = azurerm_network_interface.nic_vm1.id
  ip_configuration_name = "ipconfig1"
  nat_rule_id           = azurerm_lb_nat_rule.ssh_vm1.id
}

resource "azurerm_network_interface_nat_rule_association" "nic_vm2_nat" {
  network_interface_id  = azurerm_network_interface.nic_vm2.id
  ip_configuration_name = "ipconfig1"
  nat_rule_id           = azurerm_lb_nat_rule.ssh_vm2.id
}

resource "azurerm_network_interface_backend_address_pool_association" "nic_vm1_lb_pool" {
  network_interface_id    = azurerm_network_interface.nic_vm1.id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend_pool.id
}

resource "azurerm_network_interface_backend_address_pool_association" "nic_vm2_lb_pool" {
  network_interface_id    = azurerm_network_interface.nic_vm2.id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend_pool.id
}

resource "azurerm_linux_virtual_machine" "web_server1" {
  name                            = "WebServerLB1"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.web_vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  zone                            = "1"
  disable_password_authentication = false
  custom_data                     = base64encode(local.cloud_init_webserver)
  network_interface_ids           = [azurerm_network_interface.nic_vm1.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "web_server2" {
  name                            = "WebServerLB2"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.web_vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  zone                            = "1"
  disable_password_authentication = false
  custom_data                     = base64encode(local.cloud_init_webserver)
  network_interface_ids           = [azurerm_network_interface.nic_vm2.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# =====================================================
# Tool VM (monitoring / packet capture)
# =====================================================
resource "azurerm_public_ip" "tool_vm_public_ip" {
  name                = "ToolVM-PublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_network_interface" "tool_nic" {
  name                = "ToolNic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.tool_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tool_vm_public_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "tool_vm_nsg" {
  network_interface_id      = azurerm_network_interface.tool_nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "tool_vm" {
  name                            = "ToolGWLBVM"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.tool_vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  zone                            = "1"
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.tool_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt update -y
    apt install -y net-tools tcpdump
  EOF
  )
}

# =====================================================
# vPB-1 (Zone 1) — Virtual Packet Broker
# =====================================================
resource "azurerm_public_ip" "vpb_public_ip" {
  name                = "vPB-PublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

# Management NIC (eth0) — no accelerated networking
resource "azurerm_network_interface" "vpb_nic1" {
  name                           = "vPBNic1"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.management_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vpb_public_ip.id
  }
}

# Ingress NIC (eth1) — accelerated networking for DPDK
resource "azurerm_network_interface" "vpb_nic2" {
  name                           = "vPB_Ingress"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.provider_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.1.5"
  }
}

# Egress NIC (eth2) — accelerated networking for tool mirror
resource "azurerm_network_interface" "vpb_nic3" {
  name                           = "vPBN_Egress"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.tool_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "vpb_nic1_nsg" {
  network_interface_id      = azurerm_network_interface.vpb_nic1.id
  network_security_group_id = azurerm_network_security_group.vpb_nsg.id
  depends_on                = [azurerm_linux_virtual_machine.vpb_vm]
}

resource "azurerm_network_interface_security_group_association" "vpb_nic2_nsg" {
  network_interface_id      = azurerm_network_interface.vpb_nic2.id
  network_security_group_id = azurerm_network_security_group.vpb_nsg.id
  depends_on                = [azurerm_linux_virtual_machine.vpb_vm]
}

resource "azurerm_network_interface_security_group_association" "vpb_nic3_nsg" {
  network_interface_id      = azurerm_network_interface.vpb_nic3.id
  network_security_group_id = azurerm_network_security_group.vpb_nsg.id
  depends_on                = [azurerm_linux_virtual_machine.vpb_vm]
}

resource "azurerm_linux_virtual_machine" "vpb_vm" {
  name                            = "vPB-GWLB"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.vpb_vm_size
  admin_username                  = var.vpb_admin_username
  admin_password                  = var.vpb_admin_password
  zone                            = "1"
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.vpb_nic1.id,
    azurerm_network_interface.vpb_nic2.id,
    azurerm_network_interface.vpb_nic3.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "vpb_nic2_gwlb_pool" {
  network_interface_id    = azurerm_network_interface.vpb_nic2.id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.gw_backend_pool.id
}

# vPB-1 Install
resource "null_resource" "vpb_install" {
  depends_on = [azurerm_linux_virtual_machine.vpb_vm]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [triggers]
  }

  triggers = {
    script_checksum = filesha256(var.vpb_installer_path)
  }

  provisioner "file" {
    source      = var.vpb_installer_path
    destination = "/home/${var.vpb_admin_username}/vpb-installer.sh"

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb_public_ip.ip_address
      timeout  = "10m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sleep 10",
      "if [ ! -f /home/${var.vpb_admin_username}/.vpb_installed ]; then",
      "  chmod +x /home/${var.vpb_admin_username}/vpb-installer.sh",
      "  sudo bash /home/${var.vpb_admin_username}/vpb-installer.sh",
      "  touch /home/${var.vpb_admin_username}/.vpb_installed",
      "else",
      "  echo 'VPB already installed. Skipping...'",
      "fi"
    ]

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb_public_ip.ip_address
      timeout  = "45m"
    }
  }
}

# vPB-1 CLI Configuration
resource "null_resource" "vpb_configure" {
  depends_on = [
    null_resource.vpb_install,
    azurerm_lb.gw_lb,
    azurerm_linux_virtual_machine.tool_vm,
    azurerm_network_interface_backend_address_pool_association.vpb_nic2_gwlb_pool,
    azurerm_virtual_machine.vlm_vm
  ]

  triggers = {
    gwlb_ip = azurerm_lb.gw_lb.frontend_ip_configuration[0].private_ip_address
    tool_ip = azurerm_network_interface.tool_nic.private_ip_address
    vlm_ip  = azurerm_network_interface.vlm_nic.private_ip_address
  }

  provisioner "file" {
    content     = templatefile("${path.module}/scripts/configure_vpb.sh.tpl", {
      gwlb_ip      = azurerm_lb.gw_lb.frontend_ip_configuration[0].private_ip_address
      tool_ip      = azurerm_network_interface.tool_nic.private_ip_address
      vlm_ip       = azurerm_network_interface.vlm_nic.private_ip_address
      lb_vip       = azurerm_public_ip.lb_public_ip.ip_address
      cli_password = var.vpb_cli_password
      vpb_name     = "vPB-1"
    })
    destination = "/home/${var.vpb_admin_username}/configure_vpb.sh"

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb_public_ip.ip_address
      timeout  = "10m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.vpb_admin_username}/configure_vpb.sh",
      "sudo bash /home/${var.vpb_admin_username}/configure_vpb.sh",
    ]

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb_public_ip.ip_address
      timeout  = "30m"
    }
  }
}

# =====================================================
# vPB-2 (Zone 2) — HA Pair
# =====================================================
resource "azurerm_public_ip" "vpb2_public_ip" {
  name                = "vPB2-PublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_network_interface" "vpb2_nic1" {
  name                           = "vPB2Nic1"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.management_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vpb2_public_ip.id
  }
}

resource "azurerm_network_interface" "vpb2_nic2" {
  name                           = "vPB2_Ingress"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.provider_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.1.6"
  }
}

resource "azurerm_network_interface" "vpb2_nic3" {
  name                           = "vPB2_Egress"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.tool_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "vpb2_nic1_nsg" {
  network_interface_id      = azurerm_network_interface.vpb2_nic1.id
  network_security_group_id = azurerm_network_security_group.vpb_nsg.id
  depends_on                = [azurerm_linux_virtual_machine.vpb2_vm]
}

resource "azurerm_network_interface_security_group_association" "vpb2_nic2_nsg" {
  network_interface_id      = azurerm_network_interface.vpb2_nic2.id
  network_security_group_id = azurerm_network_security_group.vpb_nsg.id
  depends_on                = [azurerm_linux_virtual_machine.vpb2_vm]
}

resource "azurerm_network_interface_security_group_association" "vpb2_nic3_nsg" {
  network_interface_id      = azurerm_network_interface.vpb2_nic3.id
  network_security_group_id = azurerm_network_security_group.vpb_nsg.id
  depends_on                = [azurerm_linux_virtual_machine.vpb2_vm]
}

resource "azurerm_linux_virtual_machine" "vpb2_vm" {
  name                            = "vPB2-GWLB"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.vpb_vm_size
  admin_username                  = var.vpb_admin_username
  admin_password                  = var.vpb_admin_password
  zone                            = "2"
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.vpb2_nic1.id,
    azurerm_network_interface.vpb2_nic2.id,
    azurerm_network_interface.vpb2_nic3.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "vpb2_nic2_gwlb_pool" {
  network_interface_id    = azurerm_network_interface.vpb2_nic2.id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.gw_backend_pool.id
}

# vPB-2 Install
resource "null_resource" "vpb2_install" {
  depends_on = [azurerm_linux_virtual_machine.vpb2_vm]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [triggers]
  }

  triggers = {
    script_checksum = filesha256(var.vpb_installer_path)
  }

  provisioner "file" {
    source      = var.vpb_installer_path
    destination = "/home/${var.vpb_admin_username}/vpb-installer.sh"

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb2_public_ip.ip_address
      timeout  = "10m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sleep 10",
      "if [ ! -f /home/${var.vpb_admin_username}/.vpb_installed ]; then",
      "  chmod +x /home/${var.vpb_admin_username}/vpb-installer.sh",
      "  sudo bash /home/${var.vpb_admin_username}/vpb-installer.sh",
      "  touch /home/${var.vpb_admin_username}/.vpb_installed",
      "else",
      "  echo 'VPB already installed. Skipping...'",
      "fi"
    ]

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb2_public_ip.ip_address
      timeout  = "45m"
    }
  }
}

# vPB-2 CLI Configuration (identical to vPB-1)
resource "null_resource" "vpb2_configure" {
  depends_on = [
    null_resource.vpb2_install,
    azurerm_lb.gw_lb,
    azurerm_linux_virtual_machine.tool_vm,
    azurerm_network_interface_backend_address_pool_association.vpb2_nic2_gwlb_pool,
    azurerm_virtual_machine.vlm_vm
  ]

  triggers = {
    gwlb_ip = azurerm_lb.gw_lb.frontend_ip_configuration[0].private_ip_address
    tool_ip = azurerm_network_interface.tool_nic.private_ip_address
    vlm_ip  = azurerm_network_interface.vlm_nic.private_ip_address
  }

  provisioner "file" {
    content     = templatefile("${path.module}/scripts/configure_vpb.sh.tpl", {
      gwlb_ip      = azurerm_lb.gw_lb.frontend_ip_configuration[0].private_ip_address
      tool_ip      = azurerm_network_interface.tool_nic.private_ip_address
      vlm_ip       = azurerm_network_interface.vlm_nic.private_ip_address
      lb_vip       = azurerm_public_ip.lb_public_ip.ip_address
      cli_password = var.vpb_cli_password
      vpb_name     = "vPB-2"
    })
    destination = "/home/${var.vpb_admin_username}/configure_vpb.sh"

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb2_public_ip.ip_address
      timeout  = "10m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.vpb_admin_username}/configure_vpb.sh",
      "sudo bash /home/${var.vpb_admin_username}/configure_vpb.sh",
    ]

    connection {
      type     = "ssh"
      user     = var.vpb_admin_username
      password = var.vpb_admin_password
      host     = azurerm_public_ip.vpb2_public_ip.ip_address
      timeout  = "30m"
    }
  }
}

# =====================================================
# Virtual License Manager (vLM)
# =====================================================
resource "azurerm_public_ip" "vlm_public_ip" {
  name                = "vlm-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_network_security_group" "vlm_nsg" {
  name                = "vlm-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "vlm_ssh" {
  name                       = "Allow-SSH"
  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "22"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vlm_nsg.name
}

resource "azurerm_network_security_rule" "vlm_https" {
  name                       = "Allow-HTTPS"
  priority                   = 110
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "443"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vlm_nsg.name
}

resource "azurerm_network_security_rule" "vlm_http" {
  name                       = "Allow-HTTP"
  priority                   = 120
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "80"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vlm_nsg.name
}

resource "azurerm_network_interface" "vlm_nic" {
  name                = "vlm-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "vlm-ip-config"
    subnet_id                     = azurerm_subnet.management_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vlm_public_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "vlm_nic_nsg" {
  network_interface_id      = azurerm_network_interface.vlm_nic.id
  network_security_group_id = azurerm_network_security_group.vlm_nsg.id
}

resource "azurerm_storage_account" "vlm_storage" {
  name                     = "clvlmstorage${substr(md5(var.subscription_id), 0, 8)}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "vlm_vhds" {
  name                  = "vhds"
  storage_account_id    = azurerm_storage_account.vlm_storage.id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "vlm_vhd" {
  name                   = "CloudLens-vLM-1.7.vhd"
  storage_account_name   = azurerm_storage_account.vlm_storage.name
  storage_container_name = azurerm_storage_container.vlm_vhds.name
  type                   = "Page"
  source                 = var.vlm_vhd_path
}

resource "azurerm_managed_disk" "vlm_disk" {
  name                 = "vlm-os-disk"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Standard_LRS"
  os_type              = "Linux"
  hyper_v_generation   = "V1"
  create_option        = "Import"
  source_uri           = azurerm_storage_blob.vlm_vhd.url
  storage_account_id   = azurerm_storage_account.vlm_storage.id
  disk_size_gb         = 16
  depends_on           = [azurerm_storage_blob.vlm_vhd]
}

resource "azurerm_virtual_machine" "vlm_vm" {
  name                  = "vlm-vm"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.vlm_nic.id]
  vm_size               = var.vlm_vm_size

  storage_os_disk {
    name            = "vlm-os-disk"
    os_type         = "Linux"
    caching         = "ReadWrite"
    create_option   = "Attach"
    managed_disk_id = azurerm_managed_disk.vlm_disk.id
  }

  depends_on = [azurerm_network_interface_security_group_association.vlm_nic_nsg]
}
