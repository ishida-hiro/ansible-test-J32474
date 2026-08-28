# ============================================================================
# variables.tf
# ============================================================================

# ---- 全体 -------------------------------------------------------------------
variable "subscription_id" {
  description = "デプロイ先のサブスクリプション ID。空の場合は環境変数 ARM_SUBSCRIPTION_ID を使用する"
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "NSG を作成するリソースグループ名。Windows サーバが所属する既存 RG を指定する"
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name を指定してください（Windows サーバの既存リソースグループ）。"
  }
}

variable "location" {
  description = "NSG を作成するリージョン。Windows サーバと同じリージョンを指定する"
  type        = string
  default     = "japaneast"
}

variable "prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "pickles"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.prefix))
    error_message = "prefix は英小文字・数字・ハイフンの 2〜12 文字で指定してください。"
  }
}

variable "env" {
  description = "環境識別子"
  type        = string
  default     = "verify"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.env))
    error_message = "env は英小文字・数字の 2〜8 文字で指定してください。"
  }
}

variable "nsg_name" {
  description = "NSG 名。空の場合は nsg-<prefix>-<env>-windows を自動生成する"
  type        = string
  default     = ""
}

variable "owner_tag" {
  description = "全リソースに付与する Owner タグ。Terraform 管理であること（TF）と管理番号（J32474）を示す"
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

# ---- Ansible 実行サーバ（WinRM の送信元） -----------------------------------
variable "ansible_node_public_ip" {
  description = <<-EOT
    Ansible 実行サーバの Public IP（CIDR 表記。例 "203.0.113.10/32"）。
    ここからの WinRM(5986/TCP) のみを許可する。

    空にした場合は ansible_node_public_ip_name /
    ansible_node_resource_group_name から Azure 上の Public IP を自動参照する
    （terraform/ansible-node を同一サブスクリプションに構築済みであること）。
  EOT
  type        = string
  default     = ""

  validation {
    condition = var.ansible_node_public_ip == "" || can(
      regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$", var.ansible_node_public_ip)
    )
    error_message = "ansible_node_public_ip は CIDR 表記（例: 203.0.113.10/32）で指定してください。"
  }

  validation {
    condition     = var.ansible_node_public_ip != "0.0.0.0/0"
    error_message = "0.0.0.0/0 は指定できません。Ansible 実行サーバの Public IP を /32 で指定してください。"
  }
}

variable "ansible_node_public_ip_name" {
  description = "自動参照する場合の Public IP リソース名（terraform/ansible-node の既定値に合わせている）"
  type        = string
  default     = "pip-pickles-verify-ansible"
}

variable "ansible_node_resource_group_name" {
  description = "自動参照する場合の Public IP のリソースグループ名"
  type        = string
  default     = "rg-pickles-verify-ansible"
}

# ---- 運用端末（RDP の送信元） -----------------------------------------------
variable "allowed_rdp_source_addresses" {
  description = <<-EOT
    RDP(3389) を許可する送信元 CIDR のリスト。運用端末のグローバル IP を指定する。
    WinRM を有効化する bootstrap_winrm.ps1 の実行に RDP が必要。
    例: ["203.0.113.10/32"]
    ※ 0.0.0.0/0 は指定できない。
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_rdp_source_addresses) > 0
    error_message = "allowed_rdp_source_addresses を 1 件以上指定してください。"
  }

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

# ---- 追加の受信許可（任意） -------------------------------------------------
variable "additional_inbound_rules" {
  description = <<-EOT
    上記以外に許可する受信ルール。優先度 200 番台に順に割り当てられる。
    例）ファイルサーバの FTP を特定拠点にだけ開ける場合:
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
      for r in var.additional_inbound_rules : r
      if length([for c in r.source_addresses : c if c == "0.0.0.0/0" || lower(c) == "internet" || lower(c) == "*"]) > 0
    ]) == 0
    error_message = "additional_inbound_rules の source_addresses に 0.0.0.0/0 / Internet / * は指定できません。"
  }
}

# ---- 関連付け先（任意） -----------------------------------------------------
variable "network_interface_ids" {
  description = <<-EOT
    NSG を関連付ける既存 NIC のリソース ID のリスト。
    空の場合は NSG を作成するのみで関連付けは行わない（後から手動 / 別構成で関連付ける）。
    ※NIC が別の Terraform 構成で管理されている場合、関連付けの競合に注意すること。
  EOT
  type        = list(string)
  default     = []
}

variable "subnet_ids" {
  description = <<-EOT
    NSG を関連付ける既存サブネットのリソース ID のリスト。
    サブネット単位で適用したい場合に使用する。NIC 単位と併用も可能。
  EOT
  type        = list(string)
  default     = []
}
