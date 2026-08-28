# Ansible 実行用サーバ 構築手順（Terraform / HCP Terraform）

Windows サーバを構築するための **Ansible コントロールノード（Linux VM）** を
Azure 上に払い出す手順です。

| 項目 | 内容 |
| --- | --- |
| 構成 | `terraform/ansible-node`（Ansible 実行サーバ） / `terraform/windows-nsg`（Windows 側 NSG） |
| 実行方式 | HCP Terraform（VCS 駆動 / GitHub 連携） |
| Git リポジトリ | `https://github.com/ishida-hiro/ansible-test-J32474.git` |
| 接続方式 | **双方に Public IP を付与し、必要な送信元 IP × ポートのみ NSG で許可**（VNet ピアリングは使用しない） |
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
 5.  |                             |         ワークスペース作成（ansible-node）  |
 6.  |                             |                   変数を設定               |
 7.  |                             |--- push で自動 plan -> |                   |
 8.  |                             |                   Confirm & Apply ------>  Ansible 実行サーバ作成
     |                             |                        |                   |
 9. SSH 接続 <--------------------------------------------------------------- |
     |                             |                        |                   |
10. Windows サーバを作成（別構成 / 手動。Public IP 付き）------------------->  |
11.  |                             |         ワークスペース作成（windows-nsg）   |
12.  |                             |                   Confirm & Apply ------>  Windows 用 NSG 作成
13. Windows へ RDP → WinRM 有効化 ------------------------------------------> |
14. Ansible から win_ping で疎通確認                                           |
15. Playbook を配置して実行         |                        |                   |
```

所要時間の目安: 事前準備 15 分 / apply 5 分 / cloud-init 完了まで 5〜10 分

### 接続方式（構築時）

構築時は **Ansible 実行サーバ・Windows サーバの双方に Public IP を付与**し、
NSG で「必要な送信元 IP × 必要なポート」だけを許可します。

```
                  3389/TCP (RDP)
   [運用端末] ──────────────────────────────┐
       │                                     │
       │ 22/TCP (SSH)                        v
       v                          +------------------------+
+---------------------+  5986/TCP |  Windows サーバ         |
| Ansible 実行サーバ   | ────────> |  （Public IP 付き）      |
| （Public IP 付き）   |           |  windows-nsg            |
|  ansible-node       |           +------------------------+
+---------------------+
```

| 経路 | ポート | 許可元 | 設定箇所 |
| --- | --- | --- | --- |
| 運用端末 → Ansible 実行サーバ | 22/TCP | 運用端末のグローバル IP | `ansible-node` の `allowed_ssh_source_addresses` |
| 運用端末 → Windows サーバ | 3389/TCP | 運用端末のグローバル IP | `windows-nsg` の `allowed_rdp_source_addresses` |
| Ansible 実行サーバ → Windows サーバ | 5986/TCP | Ansible 実行サーバの Public IP | `windows-nsg` の `ansible_node_public_ip` |

いずれも `0.0.0.0/0` は variable の validation で拒否されます。

> ⚠ **構築時限定の措置です。**
> WinRM をインターネット経由で使うため、Ansible 側は自己署名証明書を検証しない設定
> （`ansible_winrm_server_cert_validation: ignore`）になっており、
> 経路上の中間者攻撃を検知できません。送信元 IP を `/32` に絞ることが実質的な防御です。
> 構築完了後は Public IP を外し、閉域（同一 VNet / VPN）へ移行することを推奨します。

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

## 6. HCP Terraform のワークスペースを作成する（Ansible 実行サーバ）

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

## 9. Windows サーバ用 NSG を構成する

Windows サーバ本体（VM / Public IP）は本リポジトリの管理外です。
**別途 Public IP 付きで作成したうえで**、`terraform/windows-nsg` で受信許可を構成します。

### 9.1 Ansible 実行サーバの Public IP を確認する

WinRM の許可元になります。HCP のワークスペース **Outputs** の
`ansible_node_source_cidr`（例: `203.0.113.11/32`）を控えます。

ローカル実行の場合:

```bash
terraform -chdir=terraform/ansible-node output -raw ansible_node_source_cidr
```

> この値を明示せず、Azure 上の Public IP リソースから**自動参照**させることもできます
> （`ansible_node_public_ip` を空にする）。Ansible 実行サーバを作り直した際に
> 追従できるため、こちらを推奨します。

### 9.2 ワークスペースを作成する

`ansible-node` とは **別ワークスペース**にします（state を分けるため）。

1. **New workspace → Version control workflow** → `ishida-hiro/ansible-test-J32474`
2. **Workspace Name**: `ansible-test-J32474-windows-nsg`（任意）
3. **Working Directory** に `terraform/windows-nsg` を設定
4. **Environment variables** は `ansible-node` と同じ 4 件を設定
   （`ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID`）

### 9.3 Terraform variables を設定する

| キー | 値の例 | HCL | 必須 |
| --- | --- | --- | --- |
| `resource_group_name` | `rg-pickles-windows`（Windows サーバの既存 RG） | | ✅ |
| `allowed_rdp_source_addresses` | `["203.0.113.10/32"]` | ✅ **オン** | ✅ |
| `ansible_node_public_ip` | `203.0.113.11/32`（空なら自動参照） | | |
| `location` | `japaneast` | | |
| `network_interface_ids` | `["/subscriptions/.../nic-S-AZR-007"]` | ✅ **オン** | |

`network_interface_ids` を指定すると NSG が各 NIC に自動で関連付きます。
空のままにすると **NSG を作成するだけ**なので、Azure Portal 等で手動関連付けが必要です。

### 9.4 apply して許可内容を確認する

**Start new run** → plan 確認 → **Confirm & Apply**。

作成される受信規則:

| 優先度 | 名前 | ポート | 送信元 | 用途 |
| --- | --- | --- | --- | --- |
| 100 | `Allow-RDP-Inbound` | 3389/TCP | 運用端末 | WinRM 有効化・初期設定 |
| 110 | `Allow-WinRM-Inbound` | 5986/TCP | Ansible 実行サーバ | Playbook 実行 |
| 200〜 | （追加分） | 任意 | 任意 | `additional_inbound_rules` |
| 4000 | `Deny-All-Inbound` | すべて | すべて | 上記以外を拒否 |

Outputs の `allowed_inbound` で許可内容を一覧できます。

```bash
az network nsg rule list \
  --nsg-name nsg-pickles-verify-windows \
  --resource-group rg-pickles-windows --output table
```

### 9.5 Windows サーバで WinRM を有効化する

運用端末から RDP でログオンし、管理者権限の PowerShell で実行します。

```powershell
.\bootstrap_winrm.ps1        # terraform/scripts/bootstrap_winrm.ps1
```

Azure の Custom Script Extension / RunCommand から実行しても構いません。

### 9.6 疎通を確認する

Ansible 実行サーバから確認します。

```bash
# ポート疎通
nc -vz <Windows の Public IP> 5986

# WinRM
cd ~/ansible-windows-build
ansible windows -m ansible.windows.win_ping
```

### 9.7 構築完了後に RDP を閉じる

RDP は WinRM 有効化と初期設定のために開けています。不要になったら閉じてください。

```hcl
enable_rdp_rule = false
```

---

## 10. Playbook を配置する

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

### 接続先を Public IP に設定する

構築時は Public IP 経由で WinRM 接続するため、インベントリの `ansible_host` に
**Windows サーバの Public IP** を設定します（既定値は仮の private IP です）。

```bash
vi inventory/test.yml        # ansible_host を Windows の Public IP に
```

```yaml
fileserver:
  hosts:
    Ansible-TEST-FS:
      ansible_host: 203.0.113.20      # ← Windows サーバの Public IP
```

> 閉域構成へ移行した際は、private IP に戻してください。

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

## 11. 作り直し・削除

ワークスペースが 2 つあるため、**削除は windows-nsg → ansible-node の順**で行います
（windows-nsg が ansible-node の Public IP を参照しているため）。

| 操作 | 手順 |
| --- | --- |
| 全削除 | 各ワークスペース **Settings → Destruction and Deletion → Queue destroy plan** |
| 設定変更 | コードを修正して `git push` → plan 確認 → Apply |
| VM だけ作り直す | ローカル実行時: `terraform apply -replace=azurerm_linux_virtual_machine.this` |
| RDP を閉じる | windows-nsg の `enable_rdp_rule = false` にして apply |

`ansible-node` は専用リソースグループに閉じているため、destroy でまとめて消えます。
`windows-nsg` は **既存 RG 内に NSG だけを作る**構成のため、destroy しても
Windows サーバ本体には影響しません（NSG の関連付けが外れます）。

> Ansible 実行サーバを**リソースごと再作成**すると Public IP が変わることがあります。
> その場合は windows-nsg も apply し直してください
> （`ansible_node_public_ip` を空にして自動参照にしておくと追従が容易です）。

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
| windows-nsg の apply で `Ansible 実行サーバの Public IP を解決できません` | ansible-node 未作成 / 名前不一致 | 先に ansible-node を apply する。または `ansible_node_public_ip` を明示指定する |
| `nc -vz <Windows IP> 5986` がタイムアウト | Windows 側 NSG の許可元が不一致 | windows-nsg の `ansible_node_public_ip` が現在の Ansible 実行サーバ Public IP と一致しているか確認する |
| `win_ping` が `the specified credentials were rejected` | 認証情報の誤り | `vault.yml` のユーザ / パスワードを確認する |
| `win_ping` が `certificate verify failed` | 証明書検証が有効 | `inventory/group_vars/windows.yml` の `ansible_winrm_server_cert_validation: ignore` を確認する |
| `win_ping` が `Connection refused` | WinRM 未有効化 | Windows へ RDP して `bootstrap_winrm.ps1` を実行する（手順 9.5） |

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
| [../terraform/README.md](../terraform/README.md) | 接続方式の全体像と実行順序 |
| [../terraform/ansible-node/README.md](../terraform/ansible-node/README.md) | Ansible 実行サーバ構成のリファレンス（変数一覧など） |
| [../terraform/windows-nsg/README.md](../terraform/windows-nsg/README.md) | Windows サーバ用 NSG のリファレンス |
