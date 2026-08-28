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
