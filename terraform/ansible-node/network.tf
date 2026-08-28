# ============================================================================
# network.tf : VNet / サブネット / NSG / パブリック IP / NIC
#   existing_subnet_id を指定した場合、VNet とサブネットは作成しない。
#   NSG は NIC に関連付けるため、いずれの場合も適用される。
# ============================================================================

resource "azurerm_virtual_network" "this" {
  count = local.create_network ? 1 : 0

  name                = "vnet-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "this" {
  count = local.create_network ? 1 : 0

  name                 = "snet-${local.base}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = var.subnet_address_prefixes
}

# ---- NSG --------------------------------------------------------------------
resource "azurerm_network_security_group" "this" {
  name                = "nsg-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "ssh_in" {
  name                        = "Allow-SSH-Inbound"
  description                 = "運用端末からの SSH のみ許可する"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.this.name

  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "22"
  source_address_prefixes    = var.allowed_ssh_source_addresses
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "deny_all_in" {
  name                        = "Deny-All-Inbound"
  description                 = "上記以外の受信は明示的に拒否する"
  resource_group_name         = azurerm_resource_group.this.name
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

# ---- 送信 : Windows サーバ宛の WinRM のみ明示的に許可 -----------------------
# 既定の AllowInternetOutbound より高い優先度で「意図した宛先」を明示する。
# （cloud-init のパッケージ取得等があるため、その他の送信は既定のまま許可）
resource "azurerm_network_security_rule" "winrm_out" {
  count = length(var.windows_server_public_ips) > 0 ? 1 : 0

  name                        = "Allow-WinRM-Outbound"
  description                 = "構築対象 Windows サーバへの WinRM over HTTPS のみ明示的に許可する"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.this.name

  priority                     = 100
  direction                    = "Outbound"
  access                       = "Allow"
  protocol                     = "Tcp"
  source_port_range            = "*"
  destination_port_range       = "5986"
  source_address_prefix        = "*"
  destination_address_prefixes = var.windows_server_public_ips
}

# ---- パブリック IP / NIC ----------------------------------------------------
resource "azurerm_public_ip" "this" {
  count = var.create_public_ip ? 1 : 0

  name                = "pip-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${local.base}-${random_string.suffix.result}"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.create_public_ip ? azurerm_public_ip.this[0].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}
