# terraform/

| ディレクトリ / ファイル | 用途 |
| --- | --- |
| [`ansible-node/`](ansible-node/) | **Ansible 実行用サーバ（コントロールノード）を Azure に払い出す Terraform**。検証用に専用リソースグループへ閉じ込めており、`terraform destroy` で丸ごと作り直せる |
| [`windows-nsg/`](windows-nsg/) | **別環境に既にある Windows サーバ用の NSG（単体構成）**。RDP(3389) を運用端末から、WinRM(5986) を Ansible 実行サーバからのみ許可する。検証用の Windows を `ansible-node/` で一緒に作る場合は不要 |
| `scripts/bootstrap_winrm.ps1` | 構築対象の Windows サーバで WinRM over HTTPS(5986) を有効化するスクリプト。`ansible-node` で Windows を作る場合は Run Command から自動実行される。**Run Command は BOM 無しでファイル化し PowerShell 5.1 が ANSI として読むため、本ファイルは ASCII のみで記述すること**（日本語を入れると構文エラーで apply が失敗する） |

## 接続方式（構築時）

構築時は **Ansible 実行サーバ・Windows サーバの双方に Public IP を付与**し、
NSG で「必要な送信元 IP × 必要なポート」だけを許可します。
**VNet ピアリングは使用しません。**

```
                  3389/TCP (RDP)
   [運用端末] ──────────────────────────────┐
       │                                     │
       │ 22/TCP (SSH)                        v
       v                          +------------------------+
+---------------------+  5986/TCP |  Windows サーバ         |
| Ansible 実行サーバ   | ────────> |  （Public IP 付き）      |
| （Public IP 付き）   |           |  Windows 用 NSG         |
| VNet 10.90.0.0/16   |           |  VNet 10.91.0.0/16      |
+---------------------+           +------------------------+
        ピアリングしない ＝ 通信は必ず Public IP 経由
```

| 経路 | ポート | 許可元 | 設定箇所（`ansible-node` で Windows も作る場合） | 設定箇所（既存 Windows に `windows-nsg` を当てる場合） |
| --- | --- | --- | --- | --- |
| 運用端末 → Ansible 実行サーバ | 22/TCP | 運用端末のグローバル IP | `allowed_ssh_source_addresses` | 同左 |
| 運用端末 → Windows サーバ | 3389/TCP | 運用端末のグローバル IP | `allowed_rdp_source_addresses`（空なら SSH と同じ値） | `windows-nsg` の `allowed_rdp_source_addresses` |
| Ansible 実行サーバ → Windows サーバ | 5986/TCP | Ansible 実行サーバの Public IP | **自動**（同一構成内で相互参照する） | `windows-nsg` の `ansible_node_public_ip` |

いずれも `0.0.0.0/0` は variable の validation で拒否されます。

> **構築時限定の措置です。** WinRM をインターネット経由で使うため、
> 構築完了後は Public IP を外し、閉域（同一 VNet / VPN）へ移行することを推奨します。
> 詳細は [`windows-nsg/README.md`](windows-nsg/README.md) の注意事項を参照してください。

## 実行順序

### パターン 1: 検証用の Windows も一緒に作る（既定・推奨）

`ansible-node/` の 1 ワークスペースだけで完結します。
Windows サーバ・その NSG・専用 VNet・Public IP まで同じリソースグループに作られ、
NSG の相互許可（Ansible の Public IP ⇔ Windows の Public IP）も自動で設定されます。

```
1. terraform/ansible-node   apply
     → Ansible 実行サーバ + Windows サーバ + 両者の NSG を一括作成
     → WinRM(5986) は Run Command で bootstrap_winrm.ps1 が自動実行され有効化済み
2. terraform output windows_public_ip_address を inventory の ansible_host に設定
3. Ansible 実行サーバから win_ping で疎通確認 → Playbook 実行
```

`windows-nsg/` は使いません。

### パターン 2: 別環境に既にある Windows サーバを構築対象にする

`ansible-node/` の変数を `create_windows_server = false` にします。

```
1. terraform/ansible-node   apply   → Ansible 実行サーバと Public IP が確定
     （create_windows_server = false / windows_server_public_ips に対象 IP を指定）
2. Windows サーバ VM を作成（別構成 / 手動。Public IP を付与）
3. terraform/windows-nsg    apply   → NSG 作成・Windows の NIC へ関連付け
4. Windows サーバへ RDP → scripts/bootstrap_winrm.ps1 で WinRM を有効化
5. Ansible 実行サーバから win_ping で疎通確認 → Playbook 実行
```

## 構築対象の Windows サーバ（7台）について

Windows サーバ**本体**の払い出しは本リポジトリのスコープ外です
（IP アドレス・ディスク構成は別紙「【ピックルスコーポレーション様】Azure構成パラメータシート」
に従って払い出す前提。設計書 1.4 / 1.5 の注記を参照）。
**NSG のみ** `windows-nsg/` で管理します。

ただし **検証用の 1 台**（`inventory/test.yml` の `Ansible-TEST-FS` 相当）は
`ansible-node/windows.tf` で払い出せるようにしています（`create_windows_server = true`）。
WinRM の有効化も `azurerm_virtual_machine_run_command` から
`scripts/bootstrap_winrm.ps1` が自動実行されるため、
apply 完了後そのまま Ansible で構築を開始できます。

## 使い方

```bash
# 1. Ansible 実行サーバ
cd terraform/ansible-node
cp terraform.tfvars.example terraform.tfvars   # 運用端末のグローバル IP を設定
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init && terraform apply
terraform output -raw ansible_node_source_cidr # → windows-nsg に渡す値

# 2. Windows サーバ用 NSG
cd ../windows-nsg
cp terraform.tfvars.example terraform.tfvars   # RG 名・運用端末 IP・NIC を設定
terraform init && terraform apply
```

詳細は各ディレクトリの README、通しの手順は
[`docs/04_Ansible実行サーバ構築手順.md`](../docs/04_Ansible実行サーバ構築手順.md) を参照してください。
