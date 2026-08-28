# ============================================================================
# outputs.tf
# ============================================================================

output "resource_group_name" {
  description = "作成したリソースグループ名（terraform destroy でまとめて削除される）"
  value       = azurerm_resource_group.this.name
}

output "vm_name" {
  description = "Ansible 実行用サーバの VM 名"
  value       = azurerm_linux_virtual_machine.this.name
}

output "private_ip_address" {
  description = "プライベート IP アドレス（Windows サーバからの到達性確認に使用）"
  value       = azurerm_network_interface.this.private_ip_address
}

output "public_ip_address" {
  description = "パブリック IP アドレス"
  value       = var.create_public_ip ? azurerm_public_ip.this[0].ip_address : null
}

output "fqdn" {
  description = "パブリック IP の FQDN"
  value       = var.create_public_ip ? azurerm_public_ip.this[0].fqdn : null
}

output "ssh_command" {
  description = "接続用の SSH コマンド"
  value = var.create_public_ip ? format(
    "ssh %s@%s",
    var.admin_username,
    azurerm_public_ip.this[0].fqdn,
  ) : format("ssh %s@%s  # Bastion / VPN 経由", var.admin_username, azurerm_network_interface.this.private_ip_address)
}

output "upload_playbook_command" {
  description = "運用端末から Playbook 一式を転送するコマンド"
  value = var.create_public_ip ? format(
    "rsync -av --exclude .git --exclude logs --exclude evidence ../../ %s@%s:~/ansible-windows-build/",
    var.admin_username,
    azurerm_public_ip.this[0].fqdn,
  ) : "（パブリック IP 無効のため Bastion / VPN 経由で転送してください）"
}

output "ansible_node_source_cidr" {
  description = <<-EOT
    Windows サーバ側 NSG で WinRM(5986) の送信元として許可すべき CIDR。
    terraform/windows-nsg の変数 ansible_node_public_ip にこの値を設定する。
  EOT
  value = var.create_public_ip ? "${azurerm_public_ip.this[0].ip_address}/32" : "${azurerm_network_interface.this.private_ip_address}/32"
}

output "setup_status_command" {
  description = "初期セットアップ（cloud-init）の完了確認コマンド"
  value       = "cloud-init status --wait && cat /var/log/ansible-node-setup.done"
}

output "applied_tags" {
  description = "全リソースに付与しているタグ"
  value       = local.common_tags
}

output "vnet_id" {
  description = "本モジュールが作成した VNet のリソース ID"
  value       = local.create_network ? azurerm_virtual_network.this[0].id : null
}
