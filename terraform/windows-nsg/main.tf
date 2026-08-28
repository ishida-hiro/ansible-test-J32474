# ============================================================================
# main.tf : Windows サーバ用 NSG
#
#   構築時は Windows サーバにも Public IP を付与し、
#   「必要な送信元 IP × 必要なポート」だけを許可する方針。
#
#     受信 3389/TCP ← 運用端末のグローバル IP     （WinRM 有効化・初期設定用）
#     受信 5986/TCP ← Ansible 実行サーバの Public IP（Ansible 実行用）
#     上記以外の受信は明示的に拒否
#
#   ※Windows サーバの VM / Public IP 本体は本構成の管理外。
#     別途作成したうえで、本 NSG を NIC またはサブネットへ関連付ける。
# ============================================================================

locals {
  base     = "${var.prefix}-${var.env}-windows"
  nsg_name = var.nsg_name != "" ? var.nsg_name : "nsg-${local.base}"

  # Ansible 実行サーバの Public IP。変数指定が無ければ Azure 上の実リソースを参照する
  ansible_node_cidr = (
    var.ansible_node_public_ip != ""
    ? var.ansible_node_public_ip
    : "${data.azurerm_public_ip.ansible_node[0].ip_address}/32"
  )

  common_tags = merge(
    {
      Project     = var.prefix
      Environment = var.env
      Role        = "windows-server-nsg"
      ManagedBy   = "terraform"
      Module      = "terraform/windows-nsg"
    },
    var.tags,
    {
      Owner = var.owner_tag
    },
  )
}

# 変数未指定時に terraform/ansible-node の Public IP を自動参照する
data "azurerm_public_ip" "ansible_node" {
  count = var.ansible_node_public_ip == "" ? 1 : 0

  name                = var.ansible_node_public_ip_name
  resource_group_name = var.ansible_node_resource_group_name
}

resource "azurerm_network_security_group" "this" {
  name                = local.nsg_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  lifecycle {
    precondition {
      condition     = can(cidrhost(local.ansible_node_cidr, 0))
      error_message = <<-EOT
        Ansible 実行サーバの Public IP を解決できません。
        ・terraform/ansible-node を先に apply し、出力 ansible_node_source_cidr の値を
          変数 ansible_node_public_ip に設定してください。
        ・または ansible_node_public_ip_name / ansible_node_resource_group_name が
          実際の Public IP リソースと一致しているか確認してください。
      EOT
    }
  }
}

# ---- 受信 : RDP（運用端末から。WinRM 有効化と初期設定に使用） ---------------
resource "azurerm_network_security_rule" "rdp_in" {
  count = var.enable_rdp_rule ? 1 : 0

  name                        = "Allow-RDP-Inbound"
  description                 = "運用端末からの RDP のみ許可する（WinRM 有効化・初期設定用）"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name

  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "3389"
  source_address_prefixes    = var.allowed_rdp_source_addresses
  destination_address_prefix = "*"
}

# ---- 受信 : WinRM（Ansible 実行サーバから） ---------------------------------
resource "azurerm_network_security_rule" "winrm_in" {
  name                        = "Allow-WinRM-Inbound"
  description                 = "Ansible 実行サーバからの WinRM over HTTPS のみ許可する"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name

  priority                   = 110
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "5986"
  source_address_prefix      = local.ansible_node_cidr
  destination_address_prefix = "*"
}

# ---- 受信 : 追加ルール（任意） ----------------------------------------------
resource "azurerm_network_security_rule" "additional_in" {
  for_each = { for i, r in var.additional_inbound_rules : r.name => merge(r, { index = i }) }

  name                        = each.value.name
  description                 = each.value.description
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name

  priority                   = 200 + each.value.index
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = each.value.protocol
  source_port_range          = "*"
  destination_port_range     = each.value.port
  source_address_prefixes    = each.value.source_addresses
  destination_address_prefix = "*"
}

# ---- 受信 : 上記以外は明示的に拒否 ------------------------------------------
resource "azurerm_network_security_rule" "deny_all_in" {
  name                        = "Deny-All-Inbound"
  description                 = "上記以外の受信は明示的に拒否する"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name

  priority                   = 4000
  direction                  = "Inbound"
  access                     = "Deny"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
}

# ---- 関連付け（任意） -------------------------------------------------------
resource "azurerm_network_interface_security_group_association" "this" {
  for_each = toset(var.network_interface_ids)

  network_interface_id      = each.value
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = toset(var.subnet_ids)

  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.this.id
}
