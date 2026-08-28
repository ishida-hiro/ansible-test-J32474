# ============================================================================
# providers.tf
#
#   【ローカル実行】Azure CLI（az login）で認証する。
#     export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
#
#   【HCP Terraform 実行】サービスプリンシパルの認証情報を
#     ワークスペースの「Environment variables」に設定する。
#       ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
# ============================================================================
provider "azurerm" {
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {}
}
