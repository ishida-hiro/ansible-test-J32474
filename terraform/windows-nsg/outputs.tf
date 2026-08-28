# ============================================================================
# outputs.tf
# ============================================================================

output "network_security_group_id" {
  description = "作成した NSG のリソース ID。NIC / サブネットへの関連付けに使用する"
  value       = azurerm_network_security_group.this.id
}

output "network_security_group_name" {
  description = "作成した NSG 名"
  value       = azurerm_network_security_group.this.name
}

output "ansible_node_source_cidr" {
  description = "WinRM(5986) の送信元として許可している CIDR（Ansible 実行サーバ）"
  value       = local.ansible_node_cidr
}

output "allowed_inbound" {
  description = "許可している受信の一覧（確認用）"
  value = concat(
    var.enable_rdp_rule ? [
      { port = "3389", protocol = "Tcp", from = join(",", var.allowed_rdp_source_addresses), purpose = "RDP（運用端末 / WinRM 有効化・初期設定）" }
    ] : [],
    [
      { port = "5986", protocol = "Tcp", from = local.ansible_node_cidr, purpose = "WinRM over HTTPS（Ansible 実行サーバ）" }
    ],
    [
      for r in var.additional_inbound_rules :
      { port = r.port, protocol = r.protocol, from = join(",", r.source_addresses), purpose = coalesce(r.description, r.name) }
    ],
  )
}

output "associated_network_interface_ids" {
  description = "本 NSG を関連付けた NIC の一覧"
  value       = var.network_interface_ids
}

output "associated_subnet_ids" {
  description = "本 NSG を関連付けたサブネットの一覧"
  value       = var.subnet_ids
}

output "applied_tags" {
  description = "NSG に付与しているタグ"
  value       = local.common_tags
}
