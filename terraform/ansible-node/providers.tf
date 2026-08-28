# ============================================================================
# providers.tf
#
#   【ローカル実行】Azure CLI（az login）で認証する。
#     export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
#
#   【HCP Terraform 実行】リモート実行環境に az login は無いため、
#     サービスプリンシパルの認証情報をワークスペースの
#     「Environment variables」に設定する（ARM_CLIENT_SECRET は Sensitive）。
#       ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
# ============================================================================
provider "azurerm" {
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {
    resource_group {
      # 検証環境の作り直しを容易にするため、RG 内にリソースが残っていても削除する
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      delete_os_disk_on_deletion     = true
      skip_shutdown_and_force_delete = false
    }
  }
}

provider "random" {}
