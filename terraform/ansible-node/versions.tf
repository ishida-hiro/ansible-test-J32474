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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ---- 状態ファイル ---------------------------------------------------------
  # 【HCP Terraform で実行する場合】
  #
  # ■ VCS 駆動（GitHub 連携）で実行する ... 既定。cloud ブロックは不要
  #     HCP のワークスペース側で GitHub リポジトリと
  #     Working Directory = terraform/ansible-node を設定する。
  #     git push すると自動で plan が走る。state は HCP が管理する。
  #
  # ■ CLI 駆動（手元の terraform コマンドから HCP 上で実行）にする場合
  #     以下のコメントを外し、organization を自分の組織名に変更してから
  #     terraform login → terraform init を実行する。
  #     ※ VCS 駆動と併用はできない（どちらか一方）
  #
  # cloud {
  #   organization = "<HCP-Terraform-の組織名>"
  #
  #   workspaces {
  #     name = "ansible-test-J32474"
  #   }
  # }
  #
  # 【ローカルで実行する場合】
  #   上記をすべてコメントのままにすればローカル state になる（検証用途）。
}
