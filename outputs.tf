# =====================================================
# Outputs
# =====================================================

output "load_balancer_ip" {
  description = "Standard LB public IP — use this to test HTTP traffic"
  value       = azurerm_public_ip.lb_public_ip.ip_address
}

output "vpb1_public_ip" {
  description = "vPB-1 management IP (Zone 1)"
  value       = azurerm_public_ip.vpb_public_ip.ip_address
}

output "vpb2_public_ip" {
  description = "vPB-2 management IP (Zone 2)"
  value       = azurerm_public_ip.vpb2_public_ip.ip_address
}

output "tool_vm_public_ip" {
  description = "Tool VM public IP for packet capture verification"
  value       = azurerm_public_ip.tool_vm_public_ip.ip_address
}

output "vlm_public_ip" {
  description = "Virtual License Manager public IP"
  value       = azurerm_public_ip.vlm_public_ip.ip_address
}

output "gwlb_private_ip" {
  description = "Gateway Load Balancer frontend private IP"
  value       = azurerm_lb.gw_lb.frontend_ip_configuration[0].private_ip_address
}

output "vlm_private_ip" {
  description = "vLM private IP (used by vPB license config)"
  value       = azurerm_network_interface.vlm_nic.private_ip_address
}

output "ssh_instructions" {
  description = "SSH access instructions for all components"
  value       = <<-EOF

    === SSH Access ===

    Web Servers (via Standard LB NAT):
      WebServer1: ssh ${var.admin_username}@${azurerm_public_ip.lb_public_ip.ip_address} -p 60001
      WebServer2: ssh ${var.admin_username}@${azurerm_public_ip.lb_public_ip.ip_address} -p 60002

    vPB CLI Access (two-hop SSH):
      vPB-1: ssh ${var.vpb_admin_username}@${azurerm_public_ip.vpb_public_ip.ip_address}
             then: ssh admin@localhost -p 2222 (password: ${var.vpb_cli_password})
      vPB-2: ssh ${var.vpb_admin_username}@${azurerm_public_ip.vpb2_public_ip.ip_address}
             then: ssh admin@localhost -p 2222 (password: ${var.vpb_cli_password})

    Tool VM:
      ssh ${var.admin_username}@${azurerm_public_ip.tool_vm_public_ip.ip_address}

    vLM GUI:
      https://${azurerm_public_ip.vlm_public_ip.ip_address}

    === Quick Verification ===
    curl http://${azurerm_public_ip.lb_public_ip.ip_address}
    ssh ${var.admin_username}@${azurerm_public_ip.tool_vm_public_ip.ip_address} "sudo tcpdump -c 10 -i eth0 udp port 4789"

  EOF
}
