# terraform/ansible-node — Ansible 実行用サーバ（検証環境）

Ansible のコントロールノード（Playbook を実行する Linux サーバ）を Azure 上に払い出します。

**検証用のため、専用のリソースグループにすべてのリソースを閉じ込めています。**
`terraform destroy` を実行すればリソースグループごと消えるため、何度でも作り直せます。

実行方式は **HCP Terraform（VCS 駆動）** を想定しています。ローカル実行も可能です。

---

## 作成されるリソース

| リソース | 名前（既定） | 備考 |
| --- | --- | --- |
| リソースグループ | `rg-pickles-verify-ansible` | すべてここに閉じ込める |
| 仮想ネットワーク | `vnet-pickles-verify-ansible` | `10.90.0.0/16`（既存サブネット利用時は作成しない） |
| サブネット | `snet-pickles-verify-ansible` | `10.90.1.0/24` |
| ネットワークセキュリティグループ | `nsg-pickles-verify-ansible` | 指定した送信元からの SSH(22) のみ許可、他は明示的に拒否 |
| パブリック IP | `pip-pickles-verify-ansible` | Standard / Static / DNS ラベル付き |
| ネットワークインターフェイス | `nic-pickles-verify-ansible` | NSG を関連付け |
| 仮想マシン | `vm-pickles-verify-ansible` | Ubuntu Server 24.04 LTS / Standard_B2s / SSH 鍵認証のみ |
| 自動シャットダウン | — | 毎日 21:00 (JST)。`enable_auto_shutdown = false` で無効化 |

> **VNet ピアリングは作成しません。** 構築時は Public IP 経由で Windows サーバへ接続します。
> 詳細は [Windows サーバへの到達性](#windows-サーバへの到達性) を参照してください。
> Windows サーバ側の NSG は [`terraform/windows-nsg`](../windows-nsg/README.md) で構成します。

### タグ

タグ付け可能なリソースすべてに以下を付与します。

| タグ | 値 | 備考 |
| --- | --- | --- |
| `Owner` | `TF-J32474` | `owner_tag` で変更可。`tags` による上書きは不可 |
| `Project` | `pickles` | `prefix` の値 |
| `Environment` | `verify` | `env` の値 |
| `Role` | `ansible-control-node` | 固定 |
| `ManagedBy` | `terraform` | 固定 |
| `Module` | `terraform/ansible-node` | 固定 |

`terraform output applied_tags` で実際に付与されるタグを確認できます。

> サブネット / NSG ルール / NIC-NSG 関連付けは Azure 側がタグをサポートしないため、
> タグは付与されません。

### VM 起動時の自動セットアップ（cloud-init）

- タイムゾーン `Asia/Tokyo` / ロケール `ja_JP.UTF-8`
- Python 仮想環境 `~/venv-ansible`（ログイン時に自動で有効化）
- `ansible-core` / `pywinrm` / `requests-ntlm`
- Windows 管理用コレクション（`ansible.windows` / `community.windows` / `microsoft.ad` / `ansible.utils`）
- Playbook 配置用ディレクトリ `~/ansible-windows-build`（`git_repository_url` 指定時は clone）

---

## A. HCP Terraform で実行する（推奨）

### A-0. 前提

| 項目 | 内容 |
| --- | --- |
| GitHub | 本リポジトリを push 済み |
| HCP Terraform | 組織を作成済み。GitHub と VCS 連携済み |
| Azure | サービスプリンシパル（共同作成者権限）を作成済み |
| SSH 鍵 | 手元に鍵ペアがあること（`ssh-keygen -t ed25519`） |

> **重要**: HCP のリモート実行環境には `az login` の資格情報も `~/.ssh/id_rsa.pub` も
> ありません。**Azure 認証情報と SSH 公開鍵は必ずワークスペースの変数に設定**してください。

### A-1. Azure サービスプリンシパルを作成する

手元の端末で 1 回だけ実行します。

```bash
az login
az account show --query id -o tsv          # サブスクリプション ID を控える

az ad sp create-for-rbac \
  --name "sp-tfc-ansible-J32474" \
  --role "Contributor" \
  --scopes "/subscriptions/<サブスクリプションID>"
```

出力される `appId` / `password` / `tenant` を控えます（`password` は再表示できません）。

### A-2. HCP Terraform でワークスペースを作成する

1. HCP Terraform で **New workspace → Version control workflow** を選択
2. GitHub の `ishida-hiro/ansible-test-J32474` リポジトリを選択
3. **Workspace Name**: `ansible-test-J32474`（任意）
4. **Advanced options → Working Directory** に `terraform/ansible-node` を設定
   （★これを忘れるとリポジトリ直下を Terraform 構成として読もうとして失敗します）
5. 必要に応じて **Auto-apply** を無効のままにする（plan を確認してから apply する）

### A-3. ワークスペースに変数を設定する

**Environment variables**（Azure 認証。`ARM_CLIENT_SECRET` は必ず **Sensitive** に）

| キー | 値 |
| --- | --- |
| `ARM_CLIENT_ID` | サービスプリンシパルの `appId` |
| `ARM_CLIENT_SECRET` | サービスプリンシパルの `password`（**Sensitive**） |
| `ARM_TENANT_ID` | サービスプリンシパルの `tenant` |
| `ARM_SUBSCRIPTION_ID` | サブスクリプション ID |

**Terraform variables**

| キー | 値の例 | 必須 |
| --- | --- | --- |
| `allowed_ssh_source_addresses` | `["203.0.113.10/32"]`（**HCL** をオンにする） | ✅ |
| `ssh_public_key` | `ssh-ed25519 AAAAC3Nza... user@host` | ✅ |
| `prefix` | `pickles` | |
| `env` | `verify` | |
| `location` | `japaneast` | |
| `vm_size` | `Standard_B2s` | |

自分のグローバル IP と公開鍵の確認:

```bash
curl -s https://ifconfig.me          # → allowed_ssh_source_addresses に /32 を付けて設定
cat ~/.ssh/id_ed25519.pub            # → ssh_public_key にこの 1 行をそのまま貼る
```

> `allowed_ssh_source_addresses` はリスト型のため、変数登録時に
> **HCL チェックボックスをオン**にして `["x.x.x.x/32"]` と入力してください。
> オフのままだと文字列として扱われ型エラーになります。
>
> `terraform.tfvars` は `.gitignore` 対象でリポジトリに含まれないため、
> HCP 実行時は上記のワークスペース変数だけが使われます。

### A-4. 実行する

```bash
git push          # push すると HCP 側で自動的に plan が走る
```

HCP の UI で plan 結果を確認し、**Confirm & Apply** を押します。
以降はコードを push するたびに plan が走ります。

### A-5. 出力値を確認して接続する

HCP ワークスペースの **Outputs** に `ssh_command` / `public_ip_address` / `fqdn` が表示されます。

```bash
ssh azureuser@<FQDN>

# 初期セットアップの完了確認（初回は 5〜10 分程度かかります）
cloud-init status --wait
cat /var/log/ansible-node-setup.done
```

---

## B. ローカルで実行する

state はローカル管理になります（HCP と併用しないでください）。

```bash
cd terraform/ansible-node
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars                 # allowed_ssh_source_addresses を自分のグローバル IP に

export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform plan
terraform apply
```

SSH 公開鍵は `ssh_public_key_path`（既定 `~/.ssh/id_rsa.pub`）から読み込まれます。
鍵が無い場合は `ssh-keygen -t ed25519` で作成してください。

`make` を使う場合:

```bash
make help          # 使えるターゲット一覧
make rebuild       # destroy → apply
make recreate-vm   # VM のみ作り直し
make ssh           # SSH 接続
make upload        # Playbook 転送
```

---

## Playbook を配置して実行する

```bash
# 運用端末側から転送する
rsync -av --exclude .git --exclude logs --exclude evidence \
  ../../ azureuser@<FQDN>:~/ansible-windows-build/

# もしくはサーバ側で clone する
git clone https://github.com/ishida-hiro/ansible-test-J32474.git ~/ansible-windows-build
```

```bash
# サーバ側
cd ~/ansible-windows-build
ansible --version
ansible windows -m ansible.windows.win_ping
ansible-playbook playbooks/site.yml
```

> `inventory/group_vars/all/vault.yml`（パスワード）は `.gitignore` 対象で
> **リポジトリに含まれません**。サーバ側で `vault.yml.example` から作成してください。

---

## Windows サーバへの到達性

構築時は **Ansible 実行サーバ・Windows サーバの双方に Public IP を付与**し、
NSG で「必要な送信元 IP × 必要なポート」だけを許可します。
**本モジュールは VNet ピアリングを作成しません。**

| 経路 | ポート | 許可元 | 設定箇所 |
| --- | --- | --- | --- |
| 運用端末 → Ansible 実行サーバ | 22/TCP | 運用端末のグローバル IP | 本モジュール `allowed_ssh_source_addresses` |
| Ansible 実行サーバ → Windows サーバ | 5986/TCP | — （送信側の明示許可） | 本モジュール `windows_server_public_ips` |
| 運用端末 → Windows サーバ | 3389/TCP | 運用端末のグローバル IP | `terraform/windows-nsg` |
| Ansible 実行サーバ → Windows サーバ | 5986/TCP | Ansible 実行サーバの Public IP | `terraform/windows-nsg` |

Windows サーバ側の受信許可は [`terraform/windows-nsg`](../windows-nsg/README.md) で構成します。
本モジュールの出力 `ansible_node_source_cidr` をそちらの
`ansible_node_public_ip` に渡してください（自動参照も可）。

```bash
terraform output -raw ansible_node_source_cidr    # 例: 203.0.113.11/32
```

### 送信（アウトバウンド）について

`windows_server_public_ips` に Windows サーバの Public IP を指定すると、
NSG に `Allow-WinRM-Outbound`（5986/TCP・優先度 100）が作成されます。

Azure の既定で送信はインターネット向けに許可されているため、
**この設定が無くても通信自体は可能**です。
cloud-init のパッケージ取得や `ansible-galaxy` を妨げないよう、
その他の送信は既定のまま許可しています。
本設定は「どこへ繋ぐ構成か」を NSG 上に明示し、監査時に追えるようにするためのものです。

### 閉域構成に切り替える場合

構築完了後は Public IP を外し、閉域へ移行することを推奨します。

| 構成 | 設定方法 |
| --- | --- |
| Windows サーバと同じ VNet に置く | `existing_subnet_id` に既存サブネットの ID を指定し、`create_public_ip = false` |
| VPN / ExpressRoute 経由 | 既存の接続を利用する。`create_public_ip = false` |

---

## 作り直し

```bash
# 全削除 → 再構築
terraform destroy -auto-approve && terraform apply -auto-approve

# VM だけ作り直す（ネットワーク・IP は維持）
terraform apply -replace=azurerm_linux_virtual_machine.this
```

HCP Terraform の場合は、ワークスペースの **Settings → Destruction and Deletion** から
`Queue destroy plan` を実行します。

---

## 主な変数

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `allowed_ssh_source_addresses` | （必須） | SSH を許可する送信元 CIDR。`0.0.0.0/0` は不可 |
| `ssh_public_key` | `""` | SSH 公開鍵の内容。**HCP 実行時は必須** |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | 公開鍵ファイルのパス（ローカル実行時のみ有効） |
| `prefix` / `env` | `pickles` / `verify` | リソース名の組み立てに使用 |
| `location` | `japaneast` | リージョン |
| `vm_size` | `Standard_B2s` | VM サイズ |
| `existing_subnet_id` | `""` | 指定すると既存サブネットへ配置（VNet を作成しない） |
| `create_public_ip` | `true` | パブリック IP を作成する |
| `windows_server_public_ips` | `[]` | WinRM(5986) 送信を明示許可する Windows サーバの Public IP |
| `enable_auto_shutdown` | `true` | 毎日自動シャットダウン（コスト対策） |
| `owner_tag` | `TF-J32474` | 全リソースの `Owner` タグ。`tags` より優先される |
| `git_repository_url` | `""` | 指定すると起動時に Playbook を clone する（プライベートリポジトリでは失敗するため注意） |

全変数は `variables.tf` を参照してください。

---

## 注意事項

- `terraform.tfvars` は `.gitignore` 対象です。IP やサブスクリプション ID を
  リポジトリにコミットしないでください。
- `.terraform.lock.hcl` は Linux / macOS / Windows 向けのハッシュを含めてコミットしています。
  HCP のリモート実行環境（Linux）でもそのまま使えます。
- パブリック IP を有効にしている場合、NSG の送信元 IP が変わったら
  `allowed_ssh_source_addresses` を更新して apply し直してください。
- サービスプリンシパルのシークレットには有効期限があります（既定 1 年）。
  期限切れ時は再作成してワークスペースの `ARM_CLIENT_SECRET` を更新してください。
