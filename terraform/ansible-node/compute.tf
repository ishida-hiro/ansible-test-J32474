# ============================================================================
# compute.tf : Ansible 実行用サーバ（Linux VM）
# ============================================================================

locals {
  cloud_init = templatefile("${path.module}/cloud-init/ansible-node.yaml.tftpl", {
    admin_username       = var.admin_username
    ansible_core_version = var.ansible_core_version
    ansible_collections  = var.ansible_collections
    git_repository_url   = var.git_repository_url
  })
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = "vm-${local.base}"
  computer_name       = "ansible-${var.env}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.vm_size
  tags                = local.common_tags

  network_interface_ids = [azurerm_network_interface.this.id]

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${local.base}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.source_image.publisher
    offer     = var.source_image.offer
    sku       = var.source_image.sku
    version   = var.source_image.version
  }

  custom_data = base64encode(local.cloud_init)

  boot_diagnostics {}

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    # イメージの version = "latest" による意図しない再作成を防ぐ
    ignore_changes = [source_image_reference[0].version]

    precondition {
      condition     = local.ssh_public_key != ""
      error_message = <<-EOT
        SSH 公開鍵が解決できません。
        ・HCP Terraform で実行する場合: ワークスペースの Terraform variables に
          ssh_public_key（公開鍵の内容そのもの）を設定してください。
          リモート実行環境には公開鍵ファイルが存在しないため、
          ssh_public_key_path によるファイル指定は使用できません。
        ・ローカルで実行する場合: ssh-keygen -t ed25519 で鍵を作成するか、
          ssh_public_key_path に既存の公開鍵のパスを指定してください。
      EOT
    }

    precondition {
      condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-)", local.ssh_public_key))
      error_message = "ssh_public_key は OpenSSH 形式の公開鍵（ssh-ed25519 AAAA... / ssh-rsa AAAA...）で指定してください。秘密鍵や .pub のパスではありません。"
    }
  }
}

# ---- 自動シャットダウン（検証環境のコスト対策） -----------------------------
resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  count = var.enable_auto_shutdown ? 1 : 0

  virtual_machine_id    = azurerm_linux_virtual_machine.this.id
  location              = azurerm_resource_group.this.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.common_tags

  notification_settings {
    enabled = false
  }
}
