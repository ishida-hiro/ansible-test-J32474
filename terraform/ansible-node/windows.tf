# ============================================================================
# windows.tf : 構築対象の Windows サーバ（検証用）
#
#   ・Ansible 実行サーバと同じリソースグループに作成する。
#   ・ただし VNet は分離し、ピアリングも張らない。
#     これにより Ansible 実行サーバ → Windows の通信は必ず
#     「Public IP 経由（インターネット経由）」となり、
#     実運用で想定する「別環境の Windows サーバを構築する」形を再現できる。
#
#   ・NSG は Windows 専用のものを本ファイル内で作成する
#     （terraform/windows-nsg は「既に存在する Windows サーバ」向けの
#       独立構成。同一ワークスペースで作る本構成では使用しない）。
#
#   受信許可:
#     3389/TCP ← 運用端末のグローバル IP        （初期確認・トラブル対応用）
#     5986/TCP ← Ansible 実行サーバの Public IP （Ansible 実行用）
#     上記以外は明示的に拒否
# ============================================================================

locals {
  windows_base = "${var.prefix}-${var.env}-windows"

  create_windows = var.create_windows_server

  # Public IP の DNS ラベル。
  # ★Azure は DNS ラベルに商標語を含められない★
  #   "windows" は予約語のため、そのまま使うと apply が
  #   DomainNameLabelReserved (400) で失敗する。
  #   そのためリソース名（windows）とは別に "win" へ短縮したラベルを使う。
  windows_dns_label = (
    var.windows_domain_name_label != ""
    ? var.windows_domain_name_label
    : "${var.prefix}-${var.env}-win-${random_string.suffix.result}"
  )

  # Run Command で実行する WinRM 初期設定スクリプト。
  # ASCII のみであることを下の precondition で検証する。
  winrm_bootstrap_script = file("${path.module}/../scripts/bootstrap_winrm.ps1")

  # RDP の許可元。未指定なら SSH と同じ運用端末を使う
  rdp_source_addresses = (
    length(var.allowed_rdp_source_addresses) > 0
    ? var.allowed_rdp_source_addresses
    : var.allowed_ssh_source_addresses
  )

  # 管理者パスワード。未指定なら自動生成する（出力は sensitive）
  windows_admin_password = (
    var.windows_admin_password != ""
    ? var.windows_admin_password
    : try(random_password.windows_admin[0].result, "")
  )
}

# ---- 管理者パスワードの自動生成 ---------------------------------------------
# Azure の要件: 12〜123 文字 / 大文字・小文字・数字・記号のうち 3 種類以上
resource "random_password" "windows_admin" {
  count = local.create_windows && var.windows_admin_password == "" ? 1 : 0

  length           = 24
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*+-=?_"
}

# ---- ネットワーク（Ansible 側とは別 VNet。ピアリングしない） ----------------
resource "azurerm_virtual_network" "windows" {
  count = local.create_windows ? 1 : 0

  name                = "vnet-${local.windows_base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = var.windows_vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "windows" {
  count = local.create_windows ? 1 : 0

  name                 = "snet-${local.windows_base}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.windows[0].name
  address_prefixes     = var.windows_subnet_address_prefixes
}

# ---- NSG --------------------------------------------------------------------
resource "azurerm_network_security_group" "windows" {
  count = local.create_windows ? 1 : 0

  name                = "nsg-${local.windows_base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.common_tags

  lifecycle {
    precondition {
      condition     = var.create_public_ip
      error_message = <<-EOT
        Windows サーバへは Ansible 実行サーバの Public IP から接続する構成です。
        create_public_ip = true にしてください
        （false の場合、別 VNet にいる Windows へ到達できません）。
      EOT
    }
  }
}

resource "azurerm_network_security_rule" "windows_rdp_in" {
  count = local.create_windows && var.enable_rdp_rule ? 1 : 0

  name                        = "Allow-RDP-Inbound"
  description                 = "運用端末からの RDP のみ許可する（初期確認・トラブル対応用）"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.windows[0].name

  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "3389"
  source_address_prefixes    = local.rdp_source_addresses
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "windows_winrm_in" {
  count = local.create_windows ? 1 : 0

  name                        = "Allow-WinRM-Inbound"
  description                 = "Ansible 実行サーバの Public IP からの WinRM over HTTPS のみ許可する"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.windows[0].name

  priority                   = 110
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "5986"
  source_address_prefix      = local.ansible_node_source_cidr
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "windows_additional_in" {
  for_each = local.create_windows ? { for i, r in var.windows_additional_inbound_rules : r.name => merge(r, { index = i }) } : {}

  name                        = each.value.name
  description                 = each.value.description
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.windows[0].name

  priority                   = 200 + each.value.index
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = each.value.protocol
  source_port_range          = "*"
  destination_port_range     = each.value.port
  source_address_prefixes    = each.value.source_addresses
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "windows_deny_all_in" {
  count = local.create_windows ? 1 : 0

  name                        = "Deny-All-Inbound"
  description                 = "上記以外の受信は明示的に拒否する"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.windows[0].name

  priority                   = 4000
  direction                  = "Inbound"
  access                     = "Deny"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
}

# ---- パブリック IP / NIC ----------------------------------------------------
resource "azurerm_public_ip" "windows" {
  count = local.create_windows ? 1 : 0

  name                = "pip-${local.windows_base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = local.windows_dns_label
  tags                = local.common_tags
}

resource "azurerm_network_interface" "windows" {
  count = local.create_windows ? 1 : 0

  name                = "nic-${local.windows_base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.windows[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.windows[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "windows" {
  count = local.create_windows ? 1 : 0

  network_interface_id      = azurerm_network_interface.windows[0].id
  network_security_group_id = azurerm_network_security_group.windows[0].id
}

# ---- 仮想マシン -------------------------------------------------------------
resource "azurerm_windows_virtual_machine" "this" {
  count = local.create_windows ? 1 : 0

  name                = "vm-${local.windows_base}"
  computer_name       = var.windows_computer_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.windows_vm_size
  timezone            = var.auto_shutdown_timezone
  tags                = local.common_tags

  network_interface_ids = [azurerm_network_interface.windows[0].id]

  admin_username = var.windows_admin_username
  admin_password = local.windows_admin_password

  # 更新プログラムの適用方式。
  #   Windows Server の "azure-edition" 系イメージはホットパッチ対応のため、
  #   patch_mode = "AutomaticByPlatform" を明示しないと apply が失敗する
  #   （"patch_mode" must always be set to "AutomaticByPlatform"
  #     when "source_image_reference" points to a hotpatch enabled image）。
  #   ※Ansible 側では 1.14 に従いローカル GPO の自動更新を無効化するが、
  #     ここは Azure プラットフォーム側の設定であり別物。
  patch_mode            = var.windows_patch_mode
  patch_assessment_mode = var.windows_patch_mode == "AutomaticByPlatform" ? "AutomaticByPlatform" : "ImageDefault"
  hotpatching_enabled   = var.windows_hotpatching_enabled

  os_disk {
    name                 = "osdisk-${local.windows_base}"
    caching              = "ReadWrite"
    storage_account_type = var.windows_os_disk_type
    disk_size_gb         = var.windows_os_disk_size_gb
  }

  source_image_reference {
    publisher = var.windows_source_image.publisher
    offer     = var.windows_source_image.offer
    sku       = var.windows_source_image.sku
    version   = var.windows_source_image.version
  }

  boot_diagnostics {}

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [source_image_reference[0].version]
  }
}

# ---- データディスク（Playbook の data_disks: disk_number 2 → D: に対応） -----
#   Azure の Windows VM はディスク番号 0=OS / 1=一時ディスク のため、
#   最初のデータディスク（LUN 0）が Windows 上で disk_number 2 になる。
#   一時ディスクが占有する D: は Playbook 側で Z: へ退避する
#   （inventory/group_vars/all/main.yml の azure_move_temp_drive: true）。
resource "azurerm_managed_disk" "windows_data" {
  count = local.create_windows && var.windows_data_disk_size_gb > 0 ? 1 : 0

  name                 = "datadisk-${local.windows_base}"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  storage_account_type = var.windows_data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.windows_data_disk_size_gb
  tags                 = local.common_tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "windows_data" {
  count = local.create_windows && var.windows_data_disk_size_gb > 0 ? 1 : 0

  managed_disk_id    = azurerm_managed_disk.windows_data[0].id
  virtual_machine_id = azurerm_windows_virtual_machine.this[0].id
  lun                = 0
  caching            = "None"
}

# ---- WinRM over HTTPS の初期設定 --------------------------------------------
#   terraform/scripts/bootstrap_winrm.ps1 を Run Command で実行する。
#   これにより RDP でログオンしなくても Ansible から接続できる状態になる。
#   （自己署名証明書を作成し 5986 のリスナーと OS ファイアウォールを構成する）
resource "azurerm_virtual_machine_run_command" "winrm_bootstrap" {
  count = local.create_windows && var.enable_winrm_bootstrap ? 1 : 0

  name               = "winrm-bootstrap"
  location           = azurerm_resource_group.this.location
  virtual_machine_id = azurerm_windows_virtual_machine.this[0].id

  source {
    script = local.winrm_bootstrap_script
  }

  # データディスク接続後に実行して、再起動を伴う操作と重ならないようにする
  depends_on = [azurerm_virtual_machine_data_disk_attachment.windows_data]

  lifecycle {
    precondition {
      # Run Command はスクリプトを BOM 無しでファイル化し、
      # Windows PowerShell 5.1 はそれを UTF-8 ではなく ANSI として読む。
      # そのため非 ASCII 文字（日本語コメント / メッセージ）が含まれていると
      # 文字化けして構文エラーになり、apply が VMExtensionProvisioningError で失敗する。
      #   The string is missing the terminator: '.
      # apply まで進んでから失敗しないよう、plan の時点で検出する。
      condition     = can(regex("^[\\x00-\\x7F]*$", local.winrm_bootstrap_script))
      error_message = <<-EOT
        terraform/scripts/bootstrap_winrm.ps1 に非 ASCII 文字が含まれています。
        Azure Run Command 経由では文字化けして PowerShell の構文エラーになるため、
        本スクリプトは ASCII のみで記述してください（日本語の説明はドキュメント側へ）。
        混入箇所の確認: grep -n -P '[^\x00-\x7F]' terraform/scripts/bootstrap_winrm.ps1
      EOT
    }
  }
}

# ---- 自動シャットダウン（検証環境のコスト対策） -----------------------------
resource "azurerm_dev_test_global_vm_shutdown_schedule" "windows" {
  count = local.create_windows && var.enable_auto_shutdown ? 1 : 0

  virtual_machine_id    = azurerm_windows_virtual_machine.this[0].id
  location              = azurerm_resource_group.this.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.common_tags

  notification_settings {
    enabled = false
  }
}
