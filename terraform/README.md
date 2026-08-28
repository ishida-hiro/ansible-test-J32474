# terraform/

| ディレクトリ / ファイル | 用途 |
| --- | --- |
| [`ansible-node/`](ansible-node/) | **Ansible 実行用サーバ（コントロールノード）を Azure に払い出す Terraform**。検証用に専用リソースグループへ閉じ込めており、`terraform destroy` で丸ごと作り直せる |
| `scripts/bootstrap_winrm.ps1` | 構築対象の Windows サーバで WinRM over HTTPS(5986) を有効化するスクリプト。Custom Script Extension / RunCommand / RDP のいずれかで各サーバに 1 回実行する |

## 構築対象の Windows サーバ（7台）について

Windows サーバ本体の払い出しは本リポジトリのスコープ外です
（IP アドレス・ディスク構成・NSG は別紙「【ピックルスコーポレーション様】Azure構成パラメータシート」
に従って払い出す前提。設計書 1.4 / 1.5 / 1.10 の注記を参照）。

Terraform で払い出す場合は、`azurerm_virtual_machine_extension` の
`CustomScriptExtension` から `scripts/bootstrap_winrm.ps1` を実行すると、
そのまま Ansible で構築を開始できます。

## 使い方

```bash
cd terraform/ansible-node
cp terraform.tfvars.example terraform.tfvars   # 運用端末のグローバル IP を設定
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

詳細は [`ansible-node/README.md`](ansible-node/README.md) を参照してください。
