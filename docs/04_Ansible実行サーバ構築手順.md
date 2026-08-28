# Ansible 実行用サーバ 構築手順（Terraform / HCP Terraform）

Windows サーバを構築するための **Ansible コントロールノード（Linux VM）** を
Azure 上に払い出す手順です。

| 項目 | 内容 |
| --- | --- |
| 構成 | `terraform/ansible-node` |
| 実行方式 | HCP Terraform（VCS 駆動 / GitHub 連携） |
| Git リポジトリ | `https://github.com/ishida-hiro/ansible-test-J32474.git` |
| VNet ピアリング | **作成しない** |
| 作成先 | 専用リソースグループ `rg-pickles-verify-ansible`（destroy でまとめて削除可） |

> ローカルの `terraform` コマンドで実行する場合は [付録 A](#付録-a-ローカルで実行する場合) を参照してください。

---

## 0. 全体の流れ

```
[手元の端末]                    [GitHub]              [HCP Terraform]        [Azure]
     |                             |                        |                   |
 1. SSH 鍵を用意                   |                        |                   |
 2. グローバル IP を確認           |                        |                   |
 3. サービスプリンシパル作成 ------|------------------------|-----------------> |
     |                             |                        |                   |
 4. git push ------------------->  |                        |                   |
     |                             |--- VCS 連携 ---------> |                   |
 5.  |                             |                   ワークスペース作成        |
 6.  |                             |                   変数を設定               |
 7.  |                             |--- push で自動 plan -> |                   |
 8.  |                             |                   Confirm & Apply ------>  VM 作成
     |                             |                        |                   |
 9. SSH 接続 <--------------------------------------------------------------- |
10. Playbook を配置して実行         |                        |                   |
```

所要時間の目安: 事前準備 15 分 / apply 5 分 / cloud-init 完了まで 5〜10 分

---

## 1. 前提条件

| 項目 | 内容 |
| --- | --- |
| Azure | 対象サブスクリプションへの **共同作成者** 権限。`az` CLI ログイン済み |
| GitHub | `ishida-hiro/ansible-test-J32474` への push 権限 |
| HCP Terraform | 組織を作成済み。GitHub と VCS 連携済み |
| 手元の端末 | `git` / `az` / `ssh-keygen` が使えること |

> **重要**
> HCP Terraform の**リモート実行環境には、手元の `az login` の資格情報も
> `~/.ssh/id_rsa.pub` も存在しません。**
> Azure 認証情報と SSH 公開鍵は、必ずワークスペースの変数として渡します（手順 6）。

---

## 2. SSH 鍵を用意する

VM へは**鍵認証のみ**で接続します（パスワード認証は無効）。

```bash
# 鍵が無い場合のみ作成する
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "ansible-node"

# 公開鍵の内容を表示する（手順 6 で貼り付ける）
cat ~/.ssh/id_ed25519.pub
```

出力例（この 1 行をそのまま使います）:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx ansible-node
```

---

## 3. 接続元グローバル IP を確認する

NSG で **SSH(22) をこの IP からのみ許可**します。

```bash
curl -s https://ifconfig.me; echo
```

出力例: `203.0.113.10` → 手順 6 では `["203.0.113.10/32"]` と指定します。

> `0.0.0.0/0` は variable の validation で拒否されます（インターネット全開放の防止）。
> 接続元 IP が変わったら、この変数を更新して apply し直してください。

---

## 4. Azure サービスプリンシパルを作成する

HCP のリモート実行環境では `az login` が使えないため、
サービスプリンシパル（SP）の認証情報を渡します。**1 回だけ**実施します。

```bash
az login
az account show --query id -o tsv          # サブスクリプション ID を控える

az ad sp create-for-rbac \
  --name "sp-tfc-ansible-J32474" \
  --role "Contributor" \
  --scopes "/subscriptions/<サブスクリプションID>"
```

出力例:

```json
{
  "appId":       "11111111-1111-1111-1111-111111111111",   ← ARM_CLIENT_ID
  "displayName": "sp-tfc-ansible-J32474",
  "password":    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",   ← ARM_CLIENT_SECRET
  "tenant":      "22222222-2222-2222-2222-222222222222"    ← ARM_TENANT_ID
}
```

> `password` は**この時だけしか表示されません**。控え損ねた場合は
> `az ad sp credential reset --id <appId>` で再発行してください。
> 既定の有効期限は 1 年です。期限切れ時は再発行してワークスペースの変数を更新します。

---

## 5. GitHub にコードを push する

```bash
cd /home/ubuntu/claude/ansible/ansible-windows-build

git status                      # 初回コミットは作成済み
git push -u origin main
```

`.gitignore` により以下は**リポジトリに含まれません**（意図した動作です）。

| ファイル | 内容 |
| --- | --- |
| `inventory/group_vars/all/vault.yml` | Ansible の各種パスワード |
| `terraform/ansible-node/terraform.tfvars` | IP・サブスクリプション ID 等 |
| `logs/` `evidence/` | 実行ログ・証跡 |

---

## 6. HCP Terraform のワークスペースを作成する

### 6.1 ワークスペース作成

1. HCP Terraform で **New workspace** → **Version control workflow** を選択
2. VCS プロバイダで GitHub を選び、`ishida-hiro/ansible-test-J32474` を選択
3. **Workspace Name**: `ansible-test-J32474`（任意）
4. **Advanced options** を開き、**Working Directory** に以下を設定

   ```
   terraform/ansible-node
   ```

   > ⚠ **ここが最頻出のつまずきポイントです。**
   > 未設定だとリポジトリ直下を Terraform 構成として読もうとし、
   > `No configuration files found` で失敗します。

5. **Auto-apply** は**無効のまま**にしておくことを推奨します（plan を確認してから apply）

### 6.2 Environment variables（Azure 認証）

ワークスペースの **Variables** → **Add variable** → **Environment variable** で 4 件登録します。

| キー | 値 | Sensitive |
| --- | --- | --- |
| `ARM_CLIENT_ID` | 手順 4 の `appId` | |
| `ARM_CLIENT_SECRET` | 手順 4 の `password` | ✅ **必須** |
| `ARM_TENANT_ID` | 手順 4 の `tenant` | |
| `ARM_SUBSCRIPTION_ID` | サブスクリプション ID | |

### 6.3 Terraform variables

同じ画面で **Terraform variable** として登録します。

| キー | 値の例 | HCL | 必須 |
| --- | --- | --- | --- |
| `allowed_ssh_source_addresses` | `["203.0.113.10/32"]` | ✅ **オン** | ✅ |
| `ssh_public_key` | `ssh-ed25519 AAAAC3Nza... ansible-node` | | ✅ |
| `prefix` | `pickles` | | |
| `env` | `verify` | | |
| `location` | `japaneast` | | |
| `vm_size` | `Standard_B2s` | | |

> ⚠ `allowed_ssh_source_addresses` は **list(string)** 型です。
> **HCL チェックボックスをオン**にして `["203.0.113.10/32"]` と入力してください。
> オフのまま `203.0.113.10/32` と入力すると文字列として扱われ、型エラーになります。

> ⚠ `ssh_public_key` は**公開鍵の内容そのもの**です。ファイルパスではありません。
> リモート実行環境に鍵ファイルは無いため、`ssh_public_key_path` は使えません
> （未設定のまま apply すると precondition でその旨のエラーが出ます）。

---

## 7. plan / apply を実行する

VCS 駆動なので、**push すると自動的に plan が走ります**。

```bash
git push
```

手動で流す場合は、ワークスペースの **Actions → Start new run** から実行します。

1. **Plan** の結果を確認する（想定は **9 リソース程度の追加**）
2. 問題なければ **Confirm & Apply** を押す

作成されるリソース:

| リソース | 名前（既定） |
| --- | --- |
| リソースグループ | `rg-pickles-verify-ansible` |
| 仮想ネットワーク / サブネット | `vnet-` / `snet-pickles-verify-ansible`（`10.90.0.0/16`） |
| NSG（SSH のみ許可） | `nsg-pickles-verify-ansible` |
| パブリック IP | `pip-pickles-verify-ansible` |
| NIC | `nic-pickles-verify-ansible` |
| 仮想マシン | `vm-pickles-verify-ansible`（Ubuntu 24.04 / Standard_B2s） |
| 自動シャットダウン | 毎日 21:00 JST |

---

## 8. サーバへ接続する

apply 完了後、ワークスペースの **Outputs** に接続情報が表示されます。

| 出力 | 内容 |
| --- | --- |
| `ssh_command` | 接続用の SSH コマンド |
| `public_ip_address` | パブリック IP |
| `fqdn` | DNS 名 |
| `private_ip_address` | プライベート IP（Windows 側 NSG の許可元に指定する） |

```bash
ssh azureuser@<FQDN>
```

初回はセットアップ（cloud-init）に 5〜10 分かかります。完了を待って確認します。

```bash
cloud-init status --wait
cat /var/log/ansible-node-setup.done      # ansible --version の結果が入る
```

セットアップ済みの内容:

- タイムゾーン `Asia/Tokyo` / ロケール `ja_JP.UTF-8`
- Python 仮想環境 `~/venv-ansible`（ログイン時に自動で有効化）
- `ansible-core` / `pywinrm` / `requests-ntlm`
- コレクション `ansible.windows` / `community.windows` / `microsoft.ad` / `ansible.utils`

---

## 9. Playbook を配置する

### 方法 A: サーバ側で clone する

```bash
git clone https://github.com/ishida-hiro/ansible-test-J32474.git ~/ansible-windows-build
```

### 方法 B: 手元から転送する

```bash
# 手元の端末で実行
rsync -av --exclude .git --exclude logs --exclude evidence \
  ./ansible-windows-build/ azureuser@<FQDN>:~/ansible-windows-build/
```

### 認証情報を用意する

`vault.yml` は Git に含まれないため、サーバ側で作成します。

```bash
cd ~/ansible-windows-build
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vi inventory/group_vars/all/vault.yml        # 実機のパスワードを設定

# 本番で使う場合は暗号化する
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

### 動作確認

```bash
cd ~/ansible-windows-build
ansible --version
ansible-galaxy collection list | head

# Windows サーバへの疎通（対象サーバの準備後）
ansible windows -m ansible.windows.win_ping
```

Windows サーバの構築手順は [01_構築手順.md](01_構築手順.md) を参照してください。

---

## 10. Windows サーバへの到達性について

**本構成は VNet ピアリングを作成しません。**
Ansible は WinRM over HTTPS(5986) で接続するため、別途到達性の確保が必要です。

| 構成 | 設定方法 |
| --- | --- |
| Windows サーバと同じ VNet に置く（推奨） | `existing_subnet_id` に既存サブネットの ID を指定する（VNet は作成されない） |
| VPN / ExpressRoute 経由 | 既存の接続を利用する。`create_public_ip = false` も可 |
| 別 VNet に置いてピアリングする | 本構成の範囲外。別途ピアリングを構成する |

いずれの場合も、Windows サーバ側の NSG で
**Ansible 実行用サーバのプライベート IP からの 5986/TCP を許可**してください。

---

## 11. 作り直し・削除

| 操作 | 手順 |
| --- | --- |
| 全削除 | ワークスペース **Settings → Destruction and Deletion → Queue destroy plan** |
| VM だけ作り直す | ローカル実行時: `terraform apply -replace=azurerm_linux_virtual_machine.this` |
| 設定変更 | コードを修正して `git push` → plan 確認 → Apply |

すべてのリソースが専用リソースグループに閉じているため、destroy でまとめて消えます。

---

## 12. トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `No configuration files found` | Working Directory 未設定 | ワークスペース設定で `terraform/ansible-node` を指定する（手順 6.1） |
| `Inappropriate value for attribute "allowed_ssh_source_addresses": list of string required` | 変数の HCL がオフ | 変数編集で **HCL をオン**にし `["x.x.x.x/32"]` と入力する |
| `SSH 公開鍵が解決できません` | `ssh_public_key` 未設定 | 公開鍵の**内容**を Terraform variable に設定する（手順 6.3） |
| `building AzureRM Client: ... could not configure AzureCli Authorizer` | Azure 認証情報が未設定 | Environment variables 4 件を設定する（手順 6.2） |
| `Authorization failed` / `AuthorizationFailed` | SP の権限不足 | SP に対象サブスクリプションの **Contributor** を付与する |
| SSH がタイムアウトする | 接続元 IP が NSG 許可範囲外 | `curl -s https://ifconfig.me` で現在の IP を確認し変数を更新して apply |
| SSH が `Permission denied (publickey)` | 登録した公開鍵と手元の秘密鍵が不一致 | `ssh -i ~/.ssh/id_ed25519 azureuser@<FQDN>` で鍵を明示する |
| `ansible` コマンドが無い | cloud-init 未完了 | `cloud-init status --wait` で完了を待つ |
| VM が停止している | 自動シャットダウン（毎日 21:00 JST） | Azure Portal で起動する。不要なら `enable_auto_shutdown = false` |

---

## 付録 A. ローカルで実行する場合

HCP を使わず手元の `terraform` で実行する場合の手順です。
**state はローカル管理**になるため、HCP と併用しないでください。

```bash
cd terraform/ansible-node
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars                    # allowed_ssh_source_addresses を自分の IP に

export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform plan
terraform apply
```

SSH 公開鍵は `ssh_public_key_path`（既定 `~/.ssh/id_rsa.pub`）から自動で読み込まれます。

`make` を使ったショートカット:

```bash
make help          # 使えるターゲット一覧
make plan          # 変更内容の確認
make apply         # 構築
make ssh           # SSH 接続
make upload        # Playbook 転送
make rebuild       # destroy → apply
make destroy       # 削除
```

---

## 付録 B. CLI 駆動で HCP を使う場合

手元の `terraform` コマンドから HCP 上で実行する方式です。
`terraform/ansible-node/versions.tf` の `cloud` ブロックのコメントを外し、
`organization` を自分の組織名に変更します。

```hcl
cloud {
  organization = "<HCP-Terraform-の組織名>"

  workspaces {
    name = "ansible-test-J32474"
  }
}
```

```bash
terraform login
terraform init
terraform plan          # 実行は HCP 上、出力は手元に表示される
terraform apply
```

> VCS 駆動（手順 6）と CLI 駆動は**併用できません**。どちらか一方を選んでください。

---

## 関連ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [01_構築手順.md](01_構築手順.md) | Windows サーバ（ファイルサーバ）の構築手順 |
| [02_ロール一覧.md](02_ロール一覧.md) | Ansible ロールと設計書の対応表 |
| [03_要確認事項.md](03_要確認事項.md) | 設計書の未確定・矛盾箇所 |
| [../terraform/ansible-node/README.md](../terraform/ansible-node/README.md) | Terraform 構成のリファレンス（変数一覧など） |
