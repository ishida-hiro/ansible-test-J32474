# ============================================================================
# versions.tf : Terraform / プロバイダのバージョン制約
# ============================================================================
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # ---- 状態ファイル ---------------------------------------------------------
  # 【HCP Terraform で実行する場合】
  #   VCS 駆動なら cloud ブロックは不要。ワークスペース側で
  #   Working Directory = terraform/windows-nsg を設定する。
  #   ※ansible-node とは別ワークスペースにすること（state を分ける）
  #
  # 【CLI 駆動にする場合】以下のコメントを外す
  # cloud {
  #   organization = "<HCP-Terraform-の組織名>"
  #
  #   workspaces {
  #     name = "ansible-test-J32474-windows-nsg"
  #   }
  # }
}
