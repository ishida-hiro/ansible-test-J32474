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
    Windows サーバ側 NSG で WinRM(5986) の送信元として許可している CIDR。
    本ワークスペースで Windows サーバも作成する場合は自動で適用される。
    別環境の既存 Windows に対して terraform/windows-nsg を使う場合は、
    その変数 ansible_node_public_ip にこの値を設定する。
  EOT
  value       = local.ansible_node_source_cidr
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

# ============================================================================
# 構築対象 Windows サーバ
# ============================================================================
output "windows_vm_name" {
  description = "Windows サーバの VM 名"
  value       = local.create_windows ? azurerm_windows_virtual_machine.this[0].name : null
}

output "windows_computer_name" {
  description = "Windows のコンピュータ名（インベントリのホスト名と揃える）"
  value       = local.create_windows ? azurerm_windows_virtual_machine.this[0].computer_name : null
}

output "windows_public_ip_address" {
  description = "Windows サーバのパブリック IP アドレス（Ansible はここへ接続する）"
  value       = local.create_windows ? azurerm_public_ip.windows[0].ip_address : null
}

output "windows_fqdn" {
  description = "Windows サーバのパブリック IP の FQDN"
  value       = local.create_windows ? azurerm_public_ip.windows[0].fqdn : null
}

output "windows_private_ip_address" {
  description = "Windows サーバのプライベート IP アドレス（別 VNet のため Ansible からは到達不可）"
  value       = local.create_windows ? azurerm_network_interface.windows[0].private_ip_address : null
}

output "windows_admin_username" {
  description = "Windows のローカル管理者ユーザ名（vault_local_admin_user と揃える）"
  value       = local.create_windows ? var.windows_admin_username : null
}

output "windows_admin_password" {
  description = <<-EOT
    Windows のローカル管理者パスワード。
    ローカル実行時の取得: terraform output -raw windows_admin_password
    inventory/group_vars/all/vault.yml の vault_local_admin_password に設定する。
  EOT
  value       = local.create_windows ? local.windows_admin_password : null
  sensitive   = true
}

output "windows_admin_password_generated" {
  description = <<-EOT
    自動生成したローカル管理者パスワード（windows_admin_password 未指定時のみ）。
    HCP Terraform の Outputs 画面から読めるよう、あえてマスクしていない。

    ★検証環境限定の措置★
      Windows サーバの受信は NSG で運用端末 / Ansible 実行サーバの IP に
      限定されているため、検証用途では許容している。
      マスクしたい場合は変数 windows_admin_password を明示指定すること
      （指定した場合、本出力は null になり、sensitive な
        windows_admin_password 側だけが値を持つ）。
  EOT
  value = (
    local.create_windows && var.windows_admin_password == ""
    ? nonsensitive(try(random_password.windows_admin[0].result, ""))
    : null
  )
}

output "windows_rdp_command" {
  description = "Windows サーバへの RDP 接続コマンド（Linux の xfreerdp の例）"
  value = local.create_windows ? format(
    "xfreerdp /v:%s /u:%s /cert:ignore",
    azurerm_public_ip.windows[0].ip_address,
    var.windows_admin_username,
  ) : null
}

output "windows_winrm_check_command" {
  description = "Ansible 実行サーバから WinRM(5986) の疎通を確認するコマンド"
  value       = local.create_windows ? "nc -vz ${azurerm_public_ip.windows[0].ip_address} 5986" : null
}

output "windows_inventory_snippet" {
  description = <<-EOT
    inventory/test.yml の ansible_host に設定する値。
    Ansible 実行サーバからは Public IP 経由で接続する。
  EOT
  value = local.create_windows ? format(
    "%s:\n  ansible_host: %s",
    azurerm_windows_virtual_machine.this[0].computer_name,
    azurerm_public_ip.windows[0].ip_address,
  ) : null
}
