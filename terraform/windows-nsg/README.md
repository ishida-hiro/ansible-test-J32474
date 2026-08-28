# terraform/windows-nsg — Windows サーバ用 NSG

構築対象の Windows サーバに **Public IP を付与した状態で構築する**前提で、
「必要な送信元 IP × 必要なポート」だけを許可するネットワークセキュリティグループを作成します。

```
[運用端末]                                  [Ansible 実行サーバ]
   |                                              |
   | 3389/TCP (RDP)                               | 5986/TCP (WinRM over HTTPS)
   | ※WinRM 有効化・初期設定用                     | ※Playbook 実行用
   v                                              v
+---------------------------------------------------------------+
|            Windows サーバ（Public IP 付き）                     |
|            nsg-pickles-verify-windows                          |
|              100 Allow-RDP-Inbound    3389 ← 運用端末           |
|              110 Allow-WinRM-Inbound  5986 ← Ansible 実行サーバ |
|             4000 Deny-All-Inbound     その他はすべて拒否         |
+---------------------------------------------------------------+
```

> **Windows サーバの VM / Public IP 本体は本構成の管理外です。**
> 別途作成したうえで、本 NSG を NIC またはサブネットへ関連付けてください。

---

## 作成されるリソース

| リソース | 名前（既定） | 備考 |
| --- | --- | --- |
| ネットワークセキュリティグループ | `nsg-pickles-verify-windows` | `resource_group_name` で指定した既存 RG に作成 |
| 受信規則 `Allow-RDP-Inbound` | 優先度 100 | 3389/TCP ← 運用端末。`enable_rdp_rule = false` で無効化 |
| 受信規則 `Allow-WinRM-Inbound` | 優先度 110 | 5986/TCP ← Ansible 実行サーバの Public IP |
| 受信規則（追加分） | 優先度 200〜 | `additional_inbound_rules` で任意に追加 |
| 受信規則 `Deny-All-Inbound` | 優先度 4000 | 上記以外の受信をすべて拒否 |
| NIC / サブネット関連付け | — | `network_interface_ids` / `subnet_ids` 指定時のみ |

送信規則は作成しません（Azure 既定のまま）。

---

## 実行順序

Ansible 実行サーバの Public IP が確定していないと WinRM の許可元を決められないため、
**`terraform/ansible-node` を先に apply** してください。

```
1. terraform/ansible-node を apply   → Ansible 実行サーバの Public IP が確定
2. Windows サーバ VM を作成（別構成 / 手動）→ Public IP が付与された状態にする
3. terraform/windows-nsg を apply     → NSG 作成・NIC へ関連付け
4. Windows サーバへ RDP して bootstrap_winrm.ps1 を実行（WinRM 有効化）
5. Ansible 実行サーバから win_ping で疎通確認
```

Ansible 実行サーバの Public IP は、変数で明示するか自動参照させます。

```bash
# 明示する場合（ローカル実行時）
terraform -chdir=../ansible-node output -raw ansible_node_source_cidr
# → 203.0.113.11/32  を変数 ansible_node_public_ip に設定

# 自動参照させる場合（変数を空のままにする）
#   ansible_node_public_ip_name      = "pip-pickles-verify-ansible"
#   ansible_node_resource_group_name = "rg-pickles-verify-ansible"
#   から Azure 上の Public IP を data source で読み取る
```

> Ansible 実行サーバを作り直すと Public IP が変わる場合があります
> （`allocation_method = "Static"` のため通常は維持されますが、
> リソースごと再作成した場合は変わります）。
> 自動参照にしておくと、本構成を apply し直すだけで追従できます。

---

## 手順

### A. HCP Terraform で実行する

`terraform/ansible-node` とは **別ワークスペース**を作成します（state を分けるため）。

1. **New workspace → Version control workflow** → `ishida-hiro/ansible-test-J32474`
2. **Working Directory** に `terraform/windows-nsg` を設定
3. **Environment variables**（Azure 認証。`ARM_CLIENT_SECRET` は Sensitive）
   `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID`
4. **Terraform variables**

   | キー | 値の例 | HCL | 必須 |
   | --- | --- | --- | --- |
   | `resource_group_name` | `rg-pickles-windows` | | ✅ |
   | `allowed_rdp_source_addresses` | `["203.0.113.10/32"]` | ✅ **オン** | ✅ |
   | `ansible_node_public_ip` | `203.0.113.11/32`（空なら自動参照） | | |
   | `location` | `japaneast` | | |
   | `network_interface_ids` | `["/subscriptions/.../nic-S-AZR-007"]` | ✅ **オン** | |

5. **Start new run** → plan を確認 → **Confirm & Apply**

### B. ローカルで実行する

```bash
cd terraform/windows-nsg
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars

export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform plan
terraform apply
```

---

## 許可内容の確認

```bash
terraform output allowed_inbound
```

```
[
  { port = "3389", from = "203.0.113.10/32", purpose = "RDP（運用端末 / WinRM 有効化・初期設定）" },
  { port = "5986", from = "203.0.113.11/32", purpose = "WinRM over HTTPS（Ansible 実行サーバ）" },
]
```

Azure CLI で実機の適用状態を確認する場合:

```bash
az network nsg rule list \
  --nsg-name nsg-pickles-verify-windows \
  --resource-group rg-pickles-windows \
  --output table
```

---

## 構築完了後に RDP を閉じる

RDP は WinRM 有効化と初期設定のために開けています。構築が終わったら閉じてください。

```hcl
enable_rdp_rule = false
```

```bash
terraform apply
```

---

## 主な変数

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `resource_group_name` | （必須） | NSG を作成する既存 RG（Windows サーバの RG） |
| `allowed_rdp_source_addresses` | （必須） | RDP を許可する送信元 CIDR。`0.0.0.0/0` は不可 |
| `ansible_node_public_ip` | `""` | WinRM の送信元 CIDR。空なら Azure 上の Public IP を自動参照 |
| `ansible_node_public_ip_name` | `pip-pickles-verify-ansible` | 自動参照する Public IP 名 |
| `ansible_node_resource_group_name` | `rg-pickles-verify-ansible` | 自動参照する Public IP の RG |
| `enable_rdp_rule` | `true` | RDP 許可ルールを作成するか |
| `additional_inbound_rules` | `[]` | 追加の受信許可（FTP など） |
| `network_interface_ids` | `[]` | 関連付ける既存 NIC |
| `subnet_ids` | `[]` | 関連付ける既存サブネット |
| `owner_tag` | `TF-J32474` | `Owner` タグ |

全変数は `variables.tf` を参照してください。

---

## 注意事項

- **WinRM をインターネット経由で使うのは構築時の一時的な措置です。**
  Ansible は自己署名証明書を検証しない設定（`ansible_winrm_server_cert_validation: ignore`）
  のため、経路上の中間者攻撃を検知できません。
  送信元 IP を `/32` に絞ることが実質的な防御になります。
  構築完了後は Public IP を外し、閉域（同一 VNet / VPN）へ移行することを推奨します。
- NIC が別の Terraform 構成で管理されている場合、
  `azurerm_network_interface_security_group_association` が競合する可能性があります。
  その場合は `network_interface_ids` を空にし、NIC 側の構成で
  出力 `network_security_group_id` を参照して関連付けてください。
- NSG の受信は既定でも `DenyAllInBound`（優先度 65500）が効きますが、
  意図を明示するため優先度 4000 に `Deny-All-Inbound` を置いています。
