# ============================================================================
# main.tf : リソースグループと共通定義
#   検証環境の作り直しを容易にするため、全リソースを専用のリソースグループに
#   閉じ込める。`terraform destroy` でリソースグループごと削除される。
# ============================================================================

locals {
  base = "${var.prefix}-${var.env}-ansible"

  rg_name = var.resource_group_name != "" ? var.resource_group_name : "rg-${local.base}"

  # 既存サブネットへ配置する場合は VNet を作成しない
  create_network = var.existing_subnet_id == ""

  subnet_id = local.create_network ? azurerm_subnet.this[0].id : var.existing_subnet_id

  # SSH 公開鍵の解決順:
  #   1) var.ssh_public_key（HCP Terraform ではこちらが必須）
  #   2) var.ssh_public_key_path のファイル（ローカル実行時のみ。存在しなければ空）
  # 空になった場合は compute.tf の precondition で明示的にエラーとする。
  ssh_public_key = trimspace(
    var.ssh_public_key != "" ? var.ssh_public_key : (
      fileexists(pathexpand(var.ssh_public_key_path)) ? file(pathexpand(var.ssh_public_key_path)) : ""
    )
  )

  # Owner は var.tags で上書きされないよう最後に適用する
  common_tags = merge(
    {
      Project     = var.prefix
      Environment = var.env
      Role        = "ansible-control-node"
      ManagedBy   = "terraform"
      Module      = "terraform/ansible-node"
    },
    var.tags,
    {
      Owner = var.owner_tag
    },
  )
}

# グローバルに一意な名前（パブリック IP の DNS ラベル等）に使う接尾辞
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false

  # prefix / env を変えたときだけ振り直す
  keepers = {
    base = local.base
  }
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
  tags     = local.common_tags
}
