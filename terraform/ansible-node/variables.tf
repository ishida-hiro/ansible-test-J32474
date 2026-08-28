# ============================================================================
# variables.tf
# ============================================================================

# ---- 全体 -------------------------------------------------------------------
variable "subscription_id" {
  description = "デプロイ先のサブスクリプション ID。空の場合は環境変数 ARM_SUBSCRIPTION_ID を使用する"
  type        = string
  default     = ""
}

variable "prefix" {
  description = "リソース名の接頭辞（英小文字・数字・ハイフン）"
  type        = string
  default     = "pickles"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.prefix))
    error_message = "prefix は英小文字・数字・ハイフンの 2〜12 文字で指定してください。"
  }
}

variable "env" {
  description = "環境識別子。検証環境を分離するために使用する"
  type        = string
  default     = "verify"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.env))
    error_message = "env は英小文字・数字の 2〜8 文字で指定してください。"
  }
}

variable "location" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "japaneast"
}

variable "resource_group_name" {
  description = "リソースグループ名。空の場合は rg-<prefix>-<env>-ansible を自動生成する"
  type        = string
  default     = ""
}

variable "owner_tag" {
  description = <<-EOT
    全リソースに付与する Owner タグ。
    Terraform 管理であること（TF）と管理番号（J32474）を示す。
    var.tags よりも優先されるため、追加タグで上書きされることはない。
  EOT
  type        = string
  default     = "TF-J32474"

  validation {
    condition     = length(trimspace(var.owner_tag)) > 0
    error_message = "owner_tag を空にすることはできません。"
  }
}

variable "tags" {
  description = "全リソースに付与する追加タグ（Owner は owner_tag が優先される）"
  type        = map(string)
  default     = {}
}

# ---- ネットワーク -----------------------------------------------------------
variable "existing_subnet_id" {
  description = <<-EOT
    既存サブネットへ配置する場合にそのリソース ID を指定する。
    空の場合は本モジュールが VNet / サブネットを新規作成する（既定）。
  EOT
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "新規作成する VNet のアドレス空間。Windows サーバ側の VNet と重複しない範囲にすること"
  type        = list(string)
  default     = ["10.90.0.0/16"]
}

variable "subnet_address_prefixes" {
  description = "新規作成するサブネットのアドレス範囲"
  type        = list(string)
  default     = ["10.90.1.0/24"]
}

variable "allowed_ssh_source_addresses" {
  description = <<-EOT
    SSH(22) を許可する送信元 CIDR のリスト。運用端末のグローバル IP を指定する。
    例: ["203.0.113.10/32"]
    ※ 0.0.0.0/0 は指定できない（インターネット全開放を防ぐため）。
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ssh_source_addresses) > 0
    error_message = "allowed_ssh_source_addresses を 1 件以上指定してください。"
  }

  validation {
    condition = length([
      for c in var.allowed_ssh_source_addresses : c
      if c == "0.0.0.0/0" || lower(c) == "internet" || lower(c) == "*"
    ]) == 0
    error_message = "0.0.0.0/0 / Internet / * は指定できません。運用端末のグローバル IP を指定してください。"
  }
}

variable "windows_server_public_ips" {
  description = <<-EOT
    構築対象 Windows サーバの Public IP（CIDR 表記のリスト）。
    ここに指定した宛先への WinRM(5986/TCP) 送信を NSG で明示的に許可する。
    例: ["203.0.113.20/32", "203.0.113.21/32"]

    ※Azure の既定で送信はインターネット向けに許可されているため、
      本設定が空でも通信自体は可能。意図を NSG 上に明示し、
      監査時に「どこへ繋ぐ構成か」を追えるようにするための設定。
    ※Windows 側の受信許可は terraform/windows-nsg で構成する。
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = length([
      for c in var.windows_server_public_ips : c
      if c == "0.0.0.0/0" || lower(c) == "internet" || lower(c) == "*"
    ]) == 0
    error_message = "0.0.0.0/0 / Internet / * は指定できません。Windows サーバの Public IP を /32 で指定してください。"
  }
}

variable "create_public_ip" {
  description = "パブリック IP を作成して SSH できるようにするか。false の場合は Bastion / VPN 経由の接続を前提とする"
  type        = bool
  default     = true
}

# ---- 仮想マシン -------------------------------------------------------------
variable "vm_size" {
  description = "Ansible 実行用サーバの VM サイズ"
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "管理ユーザ名"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = <<-EOT
    登録する SSH 公開鍵の内容（"ssh-ed25519 AAAA... user@host" の 1 行）。
    ★HCP Terraform で実行する場合は必須★
      リモート実行環境には運用端末の鍵ファイルが存在しないため、
      ssh_public_key_path によるファイル読み込みは使用できない。
      ワークスペースの Terraform variables に公開鍵の内容を設定すること。
    ローカル実行の場合は空のままでよく、ssh_public_key_path から読み込まれる。
  EOT
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = <<-EOT
    SSH 公開鍵ファイルのパス（ローカル実行時のフォールバック）。
    ssh_public_key を指定した場合は無視される。
    HCP Terraform のリモート実行では参照できないため ssh_public_key を使うこと。
  EOT
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "os_disk_size_gb" {
  description = "OS ディスクサイズ(GB)"
  type        = number
  default     = 64
}

variable "os_disk_type" {
  description = "OS ディスクの種類"
  type        = string
  default     = "StandardSSD_LRS"
}

variable "source_image" {
  description = <<-EOT
    使用する OS イメージ。既定は Ubuntu Server 24.04 LTS (Gen2)。
    確認コマンド: az vm image list --publisher Canonical --all --output table
  EOT
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# ---- セットアップ内容 -------------------------------------------------------
variable "ansible_core_version" {
  description = "インストールする ansible-core のバージョン指定（pip の指定子）"
  type        = string
  default     = ">=2.16"
}

variable "ansible_collections" {
  description = "初期セットアップで導入する Ansible コレクション。ansible-windows-build の requirements.yml と揃えること"
  type        = list(string)
  default = [
    "ansible.windows:>=3.0.0",
    "community.windows:>=3.0.0",
    "microsoft.ad:>=1.7.0",
    "ansible.utils",
  ]
}

variable "git_repository_url" {
  description = "初期セットアップ時に clone する Playbook リポジトリ URL。空の場合は clone しない"
  type        = string
  default     = ""
}

# ---- コスト対策 -------------------------------------------------------------
variable "enable_auto_shutdown" {
  description = "毎日決まった時刻に VM を自動シャットダウンするか（検証環境のコスト対策）"
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "自動シャットダウン時刻（HHmm 形式・auto_shutdown_timezone のローカル時刻）"
  type        = string
  default     = "2100"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "auto_shutdown_time は HHmm 形式（例: 2100）で指定してください。"
  }
}

variable "auto_shutdown_timezone" {
  description = "自動シャットダウンのタイムゾーン（Windows タイムゾーン ID）"
  type        = string
  default     = "Tokyo Standard Time"
}

# ============================================================================
# 構築対象 Windows サーバ（同一ワークスペースで作成する検証用サーバ）
#   windows.tf を参照。Ansible 実行サーバとは別 VNet に配置し、
#   Public IP 経由で接続する（別環境の Windows を構築する形を再現するため）。
# ============================================================================
variable "create_windows_server" {
  description = <<-EOT
    構築対象の Windows サーバ（VM / NSG / 別 VNet / Public IP）を
    本ワークスペースで作成するか。
    別環境に既存の Windows サーバがある場合は false にし、
    windows_server_public_ips と terraform/windows-nsg を使う。
  EOT
  type        = bool
  default     = true
}

variable "windows_vm_size" {
  description = "Windows サーバの VM サイズ。検証用途のため小さめの既定値にしている（Standard_B2s = 2vCPU/4GB）"
  type        = string
  default     = "Standard_B2s"
}

variable "windows_computer_name" {
  description = <<-EOT
    Windows のコンピュータ名（NetBIOS 名。15 文字以内）。
    inventory/test.yml の検証機ホスト名（Ansible-TEST-FS）に合わせている。
  EOT
  type        = string
  default     = "Ansible-TEST-FS"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,15}$", var.windows_computer_name))
    error_message = "windows_computer_name は英数字とハイフンの 15 文字以内で指定してください。"
  }
}

variable "windows_admin_username" {
  description = <<-EOT
    Windows のローカル管理者ユーザ名。
    Ansible の接続ユーザ（inventory/group_vars/all/vault.yml の
    vault_local_admin_user）と一致させること。
  EOT
  type        = string
  default     = "picklesadmin"

  validation {
    condition = !contains(
      ["administrator", "admin", "user", "user1", "test", "guest", "root", "server", "console"],
      lower(var.windows_admin_username)
    )
    error_message = "windows_admin_username に Azure の予約語（administrator / admin / user / guest など）は指定できません。"
  }
}

variable "windows_admin_password" {
  description = <<-EOT
    Windows のローカル管理者パスワード。
    Ansible の vault_local_admin_password と一致させること。
    検証環境では空のままでよい。空にすると自動生成し、
    出力 windows_admin_password_generated から読める
    （HCP Terraform の Outputs 画面で読めるよう、あえてマスクしていない）。
    値をマスクしたい場合のみ、Sensitive な Terraform variable として明示指定する。
    Azure の要件: 12〜123 文字 / 大文字・小文字・数字・記号のうち 3 種類以上。
  EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.windows_admin_password == "" || length(var.windows_admin_password) >= 12
    error_message = "windows_admin_password は 12 文字以上で指定してください（Azure の要件）。"
  }

  validation {
    condition     = length(var.windows_admin_password) <= 123
    error_message = "windows_admin_password は 123 文字以内で指定してください（Azure の要件）。"
  }
}

variable "windows_source_image" {
  description = <<-EOT
    Windows サーバの OS イメージ。既定は Windows Server 2025 Datacenter
    （設計書「1.概要」No.7 ファイルサーバの OS に合わせている）。
    確認コマンド:
      az vm image list --publisher MicrosoftWindowsServer --offer WindowsServer --all -o table
  EOT
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-azure-edition"
    version   = "latest"
  }
}

variable "windows_os_disk_size_gb" {
  description = "Windows の OS ディスクサイズ(GB)。イメージ既定の 127GB 以上にすること"
  type        = number
  default     = 128
}

variable "windows_os_disk_type" {
  description = "Windows の OS ディスクの種類"
  type        = string
  default     = "StandardSSD_LRS"
}

variable "windows_data_disk_size_gb" {
  description = <<-EOT
    データディスク(D: 相当)のサイズ(GB)。0 にすると作成しない。
    Playbook 側の data_disks（disk_number: 2 / drive_letter: D）に対応する。
    設計書では 2048GB だが、検証用途のため既定は小さくしている。
  EOT
  type        = number
  default     = 32

  validation {
    condition     = var.windows_data_disk_size_gb >= 0
    error_message = "windows_data_disk_size_gb は 0 以上で指定してください。"
  }
}

variable "windows_data_disk_type" {
  description = "データディスクの種類"
  type        = string
  default     = "StandardSSD_LRS"
}

variable "windows_vnet_address_space" {
  description = <<-EOT
    Windows サーバ側 VNet のアドレス空間。
    Ansible 実行サーバ側（vnet_address_space）と重複しないこと。
    ※両者はピアリングしないため、通信は Public IP 経由になる。
  EOT
  type        = list(string)
  default     = ["10.91.0.0/16"]
}

variable "windows_subnet_address_prefixes" {
  description = "Windows サーバ側サブネットのアドレス範囲"
  type        = list(string)
  default     = ["10.91.1.0/24"]
}

variable "allowed_rdp_source_addresses" {
  description = <<-EOT
    Windows サーバへの RDP(3389) を許可する送信元 CIDR のリスト。
    空の場合は allowed_ssh_source_addresses（運用端末）と同じ値を使う。
    ※ 0.0.0.0/0 は指定できない。
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = length([
      for c in var.allowed_rdp_source_addresses : c
      if c == "0.0.0.0/0" || lower(c) == "internet" || lower(c) == "*"
    ]) == 0
    error_message = "0.0.0.0/0 / Internet / * は指定できません。運用端末のグローバル IP を指定してください。"
  }
}

variable "enable_rdp_rule" {
  description = "RDP(3389) の受信許可ルールを作成するか。構築完了後に false にして閉じることを想定"
  type        = bool
  default     = true
}

variable "enable_winrm_bootstrap" {
  description = <<-EOT
    terraform/scripts/bootstrap_winrm.ps1 を Run Command で自動実行し、
    WinRM over HTTPS(5986) を有効化するか。
    false にした場合は RDP でログオンして手動実行する必要がある。
  EOT
  type        = bool
  default     = true
}

variable "windows_additional_inbound_rules" {
  description = <<-EOT
    Windows サーバ NSG に追加する受信許可ルール。優先度 200 番台に順に割り当てられる。
    例）FTP を特定拠点にだけ開ける場合:
      [{ name = "Allow-FTP", port = "21", source_addresses = ["203.0.113.30/32"] }]
  EOT
  type = list(object({
    name             = string
    port             = string
    protocol         = optional(string, "Tcp")
    source_addresses = list(string)
    description      = optional(string, "")
  }))
  default = []

  validation {
    condition = length([
      for r in var.windows_additional_inbound_rules : r
      if length([for c in r.source_addresses : c if c == "0.0.0.0/0" || lower(c) == "internet" || lower(c) == "*"]) > 0
    ]) == 0
    error_message = "windows_additional_inbound_rules の source_addresses に 0.0.0.0/0 / Internet / * は指定できません。"
  }
}
