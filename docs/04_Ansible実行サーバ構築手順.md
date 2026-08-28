# Ansible 実行用サーバ 構築手順（Terraform / HCP Terraform）

**Ansible コントロールノード（Linux VM）と、構築対象の Windows サーバを
1 つの Terraform ワークスペースでまとめて払い出す手順**です。

| 項目 | 内容 |
| --- | --- |
| 構成 | `terraform/ansible-node` の 1 ワークスペースで、Ansible 実行サーバ・Windows サーバ・両者の NSG を一括作成 |
| 実行方式 | HCP Terraform（VCS 駆動 / GitHub 連携） |
| Git リポジトリ | `https://github.com/ishida-hiro/ansible-test-J32474.git` |
| 接続方式 | **双方に Public IP を付与し、必要な送信元 IP × ポートのみ NSG で許可**（VNet ピアリングは使用しない） |
| 作成先 | 専用リソースグループ `rg-pickles-verify-ansible`（destroy でまとめて削除可） |

> ローカルの `terraform` コマンドで実行する場合は [付録 A](#付録-a-ローカルで実行する場合) を参照してください。
> 別環境に**既にある** Windows サーバを構築対象にする場合は
> [付録 C](#付録-c-別環境の既存-windows-サーバを対象にする場合) を参照してください。

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
 8.  |                             |                   Confirm & Apply ------>  Ansible 実行サーバ
     |                             |                        |                +  Windows サーバ
     |                             |                        |                +  両者の NSG / VNet / Public IP
     |                             |                        |                   （WinRM も自動で有効化）
 9. Outputs を確認（IP・パスワード）                                            |
10. Ansible 実行サーバへ SSH <----------------------------------------------- |
11. Playbook を配置し、インベントリと vault.yml を設定                          |
12. win_ping で疎通確認 → Playbook 実行                                        |
```

所要時間の目安: 事前準備 15 分 / apply 10〜15 分 / cloud-init 完了まで 5〜10 分

**Windows サーバへの WinRM 有効化まで Terraform が行う**ため、
RDP でログオンして手作業をする必要はありません。

### 接続方式（構築時）

Ansible 実行サーバと Windows サーバは**別々の VNet に置き、ピアリングもしません**。
そのため両者の通信は必ず Public IP 経由（インターネット経由）になります。
これは「別環境にある Windows サーバを構築する」実運用の形を検証環境で再現するためです。

```
                  3389/TCP (RDP)
   [運用端末] ──────────────────────────────┐
       │                                     │
       │ 22/TCP (SSH)                        v
       v                          +--------------------------+
+---------------------+  5986/TCP |  Windows サーバ           |
| Ansible 実行サーバ   | ────────> |  （Public IP 付き）        |
| （Public IP 付き）   |           |  nsg-...-windows          |
| VNet 10.90.0.0/16   |           |  VNet 10.91.0.0/16        |
+---------------------+           +--------------------------+
          └────── ピアリングしない ＝ 通信は必ず Public IP 経由 ──────┘
```

| 経路 | ポート | 許可元 | 設定箇所 |
| --- | --- | --- | --- |
| 運用端末 → Ansible 実行サーバ | 22/TCP | 運用端末のグローバル IP | `allowed_ssh_source_addresses` |
| 運用端末 → Windows サーバ | 3389/TCP | 運用端末のグローバル IP | `allowed_rdp_source_addresses`（空なら SSH と同じ値） |
| Ansible 実行サーバ → Windows サーバ | 5986/TCP | Ansible 実行サーバの Public IP | **自動**（同一構成内で相互参照するため入力不要） |

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

Ansible 実行サーバへは**鍵認証のみ**で接続します（パスワード認証は無効）。

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

> Windows サーバへは RDP（パスワード認証）で接続します。
> そのパスワードは Terraform が自動生成するため、事前準備は不要です（手順 6.3 / 8）。

---

## 3. 接続元グローバル IP を確認する

NSG で **SSH(22) と RDP(3389) をこの IP からのみ許可**します。

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

git status
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

**ワークスペースは 1 つだけ**です。ここで Ansible 実行サーバと Windows サーバの
両方を管理します。

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

> ⚠ この 4 件は必ず **Environment variable** カテゴリで登録します。
> **Terraform variable** 側に登録すると、plan のログに次の警告が出ます。
>
> ```
> Warning: Value for undeclared variable
> The root module does not declare a variable named "ARM_TENANT_ID" but a value
> was found in file "…/terraform.tfvars".
> ```
>
> これは「構成に存在しない変数に値が渡された」という**警告のみ**で plan は成功しますが、
> Terraform variable として渡された値は Azure 認証には**使われません**。
> 4 件すべてが Environment variable 側にも登録されていないと、
> apply の段階で認証エラーになります。
> 誤って登録した Terraform variable 側は削除するか、
> 変数編集画面で **Environment variable** にカテゴリを変更してください。

### 6.3 Terraform variables

同じ画面で **Terraform variable** として登録します。
**必須は 2 件だけ**で、残りは既定値のままで動きます。

| キー | 値の例 | HCL | 必須 |
| --- | --- | --- | --- |
| `allowed_ssh_source_addresses` | `["203.0.113.10/32"]` | ✅ **オン** | ✅ |
| `ssh_public_key` | `ssh-ed25519 AAAAC3Nza... ansible-node` | | ✅ |
| `prefix` | `pickles` | | |
| `env` | `verify` | | |
| `location` | `japaneast` | | |
| `vm_size` | `Standard_B2s` | | |

Windows サーバ側は既定値のままで作成されます。変更したい場合のみ登録します。

| キー | 既定値 | HCL | 説明 |
| --- | --- | --- | --- |
| `create_windows_server` | `true` | | Windows サーバ一式を作成する |
| `windows_vm_size` | `Standard_B2s` | | 検証用の小さめサイズ（2vCPU / 4GB） |
| `windows_computer_name` | `Ansible-TEST-FS` | | `inventory/test.yml` のホスト名と一致 |
| `windows_admin_username` | `picklesadmin` | | `vault_local_admin_user` と揃える |
| `windows_admin_password` | `""`（自動生成） | | 下の注記を参照 |
| `windows_data_disk_size_gb` | `32` | | `D:` 相当のデータディスク |
| `allowed_rdp_source_addresses` | `[]` | ✅ **オン** | 空なら SSH と同じ運用端末 IP を使う |
| `enable_rdp_rule` | `true` | | 構築完了後に `false` にして 3389 を閉じられる |
| `enable_winrm_bootstrap` | `true` | | WinRM を Run Command で自動有効化する |

> **Windows のパスワードは設定しなくて構いません。**
> `windows_admin_password` が空の場合、Terraform が自動生成し、
> apply 後に出力 `windows_admin_password_generated` から読めます
> （HCP の Outputs 画面で読めるよう、あえてマスクしていません）。
> その値を手順 11 で `vault_local_admin_password` に設定します。
>
> 値をマスクしたい場合のみ、**Sensitive をオンにして明示指定**します。
> Azure の要件は 12〜123 文字・大文字/小文字/数字/記号のうち 3 種類以上です。

> ⚠ `allowed_ssh_source_addresses` は **list(string)** 型です。
> **HCL チェックボックスをオン**にして `["203.0.113.10/32"]` と入力してください。
> 角かっことダブルクォートは省略できません。
>
> - HCL オフ + `203.0.113.10/32`
>   → `Inappropriate value for attribute ...: list of string required`
> - HCL オン + `203.0.113.10/32`（かっこ・クォート無し）
>   → `invalid HCL for variable ... Invalid number literal`
>   （HCL 式として解釈され `203.0...` が数値リテラル扱いになる）
> - HCL オン + `["203.0.113.10/32"]` → OK

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

1. **Plan** の結果を確認する（既定値のままなら **28 リソース程度の追加**）
2. 問題なければ **Confirm & Apply** を押す

apply には 10〜15 分程度かかります（Windows VM の作成と WinRM 設定を含むため）。

### 作成されるリソース

すべて 1 つのリソースグループ `rg-pickles-verify-ansible` に閉じ込められます。

**Ansible 実行サーバ側**

| リソース | 名前（既定） | 備考 |
| --- | --- | --- |
| リソースグループ | `rg-pickles-verify-ansible` | destroy でまとめて削除される |
| 仮想ネットワーク / サブネット | `vnet-` / `snet-pickles-verify-ansible` | `10.90.0.0/16` |
| NSG | `nsg-pickles-verify-ansible` | SSH(22) ← 運用端末 / WinRM(5986) 送信を明示許可 |
| パブリック IP | `pip-pickles-verify-ansible` | Standard / Static / DNS ラベル付き |
| NIC | `nic-pickles-verify-ansible` | |
| 仮想マシン | `vm-pickles-verify-ansible` | Ubuntu 24.04 LTS / `Standard_B2s` / 鍵認証のみ |
| 自動シャットダウン | — | 毎日 21:00 JST |

**Windows サーバ側**

| リソース | 名前（既定） | 備考 |
| --- | --- | --- |
| 仮想ネットワーク / サブネット | `vnet-` / `snet-pickles-verify-windows` | `10.91.0.0/16`。**Ansible 側とピアリングしない** |
| NSG | `nsg-pickles-verify-windows` | 下の受信規則 |
| パブリック IP | `pip-pickles-verify-windows` | Standard / Static / DNS ラベルは `pickles-verify-win-<ランダム>`（`windows` は Azure の予約語のため `win` に短縮） |
| NIC | `nic-pickles-verify-windows` | |
| 仮想マシン | `vm-pickles-verify-windows` | Windows Server 2025 Datacenter / `Standard_B2s` |
| コンピュータ名 | `Ansible-TEST-FS` | `inventory/test.yml` のホスト名と一致 |
| データディスク | `datadisk-pickles-verify-windows` | 32GB。Playbook の `data_disks`（`disk_number: 2` → `D:`）に対応 |
| Run Command | `winrm-bootstrap` | `scripts/bootstrap_winrm.ps1` を自動実行して WinRM(5986) を有効化 |
| 自動シャットダウン | — | 毎日 21:00 JST |

Windows NSG の受信規則:

| 優先度 | 名前 | ポート | 送信元 | 用途 |
| --- | --- | --- | --- | --- |
| 100 | `Allow-RDP-Inbound` | 3389/TCP | 運用端末 | 初期確認・トラブル対応 |
| 110 | `Allow-WinRM-Inbound` | 5986/TCP | Ansible 実行サーバの Public IP（**自動**） | Playbook 実行 |
| 200〜 | （追加分） | 任意 | 任意 | `windows_additional_inbound_rules` |
| 4000 | `Deny-All-Inbound` | すべて | すべて | 上記以外を拒否 |

> Ansible 実行サーバの Public IP と Windows サーバの Public IP は
> Terraform 内で相互参照しているため、**IP を手で書き写す作業はありません**。

---

## 8. Outputs を確認する

apply 完了後、ワークスペースの **Outputs** に接続情報が表示されます。
以降の手順で使うので、この 4 つを控えます。

| 出力 | 用途 |
| --- | --- |
| `ssh_command` | Ansible 実行サーバへの SSH コマンド（手順 10） |
| `windows_public_ip_address` | `inventory/test.yml` の `ansible_host` に設定（手順 11） |
| `windows_admin_username` | `vault_local_admin_user` に設定（既定 `picklesadmin`） |
| `windows_admin_password_generated` | `vault_local_admin_password` に設定（手順 11） |

その他の出力:

| 出力 | 内容 |
| --- | --- |
| `public_ip_address` / `fqdn` | Ansible 実行サーバの Public IP / DNS 名 |
| `windows_fqdn` | Windows サーバの DNS 名 |
| `windows_rdp_command` | Windows への RDP 接続コマンド |
| `windows_winrm_check_command` | WinRM の疎通確認コマンド |
| `ansible_node_source_cidr` | Windows 側 NSG が許可している送信元 CIDR |
| `upload_playbook_command` | Playbook 転送用の rsync コマンド |
| `applied_tags` | 全リソースに付与されたタグ |

ローカル実行の場合:

```bash
terraform -chdir=terraform/ansible-node output
terraform -chdir=terraform/ansible-node output -raw windows_public_ip_address
terraform -chdir=terraform/ansible-node output windows_admin_password_generated
```

> `windows_admin_password` は sensitive のため画面ではマスクされます。
> `windows_admin_password_generated`（マスクなし）を使ってください。
> `windows_admin_password` を変数で明示指定した場合、
> `windows_admin_password_generated` は `null` になります。

---

## 9. Windows サーバの状態を確認する

Terraform が Run Command で `scripts/bootstrap_winrm.ps1` を実行済みのため、
**Windows 側は追加の手作業なしで WinRM(5986) が有効**になっています。

実行済みの内容:

- WinRM サービスの自動起動化
- 自己署名証明書の作成（CN = コンピュータ名）
- HTTPS リスナー（5986）の構成
- OS ファイアウォールの受信規則追加
- 認証方式（Negotiate）とタイムアウトの設定

自動実行の結果は Azure Portal の **VM → 操作 → 実行コマンド → `winrm-bootstrap`** で確認できます。

> `enable_winrm_bootstrap = false` にした場合のみ、RDP でログオンして
> `bootstrap_winrm.ps1` を手動実行する必要があります。
> RDP コマンドは Outputs の `windows_rdp_command` に出ています。

---

## 10. Ansible 実行サーバへ接続する

```bash
ssh azureuser@<FQDN>          # Outputs の ssh_command
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

Windows サーバへのポート疎通もここで確認できます。

```bash
nc -vz <windows_public_ip_address> 5986
# → Connection to ... 5986 port [tcp/*] succeeded!
```

---

## 11. Playbook を配置して設定する

### 11.1 Playbook を配置する

**方法 A: サーバ側で clone する**

```bash
git clone https://github.com/ishida-hiro/ansible-test-J32474.git ~/ansible-windows-build
```

**方法 B: 手元から転送する**

```bash
# 手元の端末で実行（Outputs の upload_playbook_command と同じ）
rsync -av --exclude .git --exclude logs --exclude evidence \
  ./ansible-windows-build/ azureuser@<FQDN>:~/ansible-windows-build/
```

### 11.2 認証情報を設定する

`vault.yml` は Git に含まれないため、サーバ側で作成します。
**手順 8 で控えた値をそのまま設定します。**

```bash
cd ~/ansible-windows-build
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vi inventory/group_vars/all/vault.yml
```

| `vault.yml` のキー | 設定する値 | Terraform 側 |
| --- | --- | --- |
| `vault_local_admin_user` | `picklesadmin` | `windows_admin_username` |
| `vault_local_admin_password` | 自動生成されたパスワード | `windows_admin_password_generated` |

その他のキー（FTP ユーザ等）は検証用の任意の値で構いません。

```bash
# 本番で使う場合は暗号化する
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

### 11.3 接続先を Windows の Public IP に設定する

構築時は Public IP 経由で WinRM 接続するため、インベントリの `ansible_host` に
**Windows サーバの Public IP** を設定します（既定値は仮の private IP です）。

```bash
vi inventory/test.yml
```

```yaml
fileserver:
  hosts:
    Ansible-TEST-FS:
      ansible_host: 203.0.113.20      # ← Outputs の windows_public_ip_address
```

> 閉域構成へ移行した際は、private IP に戻してください。

---

## 12. 疎通確認と Playbook 実行

```bash
cd ~/ansible-windows-build

# 環境の確認
ansible --version
ansible-galaxy collection list | head

# Windows サーバへの疎通
ansible windows -m ansible.windows.win_ping -i inventory/test.yml
```

成功例:

```
Ansible-TEST-FS | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

ここまで通れば Windows サーバの構築を開始できます。
Playbook の実行手順は [01_構築手順.md](01_構築手順.md) を参照してください。

### 構築完了後に RDP を閉じる

RDP は初期確認・トラブル対応のために開けています。不要になったら閉じてください。

```hcl
enable_rdp_rule = false
```

変数を変更して apply し直すと、`Allow-RDP-Inbound` が削除されます。

---

## 13. 作り直し・削除

Ansible 実行サーバも Windows サーバも同じリソースグループに閉じているため、
**destroy 1 回でまとめて消えます**。

| 操作 | 手順 |
| --- | --- |
| 全削除 | **Settings → Destruction and Deletion → Queue destroy plan** |
| 設定変更 | コードを修正して `git push` → plan 確認 → Apply |
| Ansible 実行サーバの VM だけ作り直す | `terraform apply -replace=azurerm_linux_virtual_machine.this` |
| Windows の VM だけ作り直す | `terraform apply -replace='azurerm_windows_virtual_machine.this[0]'` |
| Windows だけ削除する | `create_windows_server = false` にして apply |
| RDP を閉じる | `enable_rdp_rule = false` にして apply |

VM だけを作り直す場合、Public IP は維持されるため NSG の許可も変わりません。

> Windows VM を作り直すと **パスワードが再生成されるわけではありません**
> （`random_password` は state に保持されます）。
> ただし Run Command による WinRM 設定は再実行されます。

ローカル実行時のショートカット:

```bash
cd terraform/ansible-node
make rebuild            # destroy → apply
make recreate-windows   # Windows の VM だけ作り直す
make winpass            # Windows のパスワードを表示
make wincheck           # Ansible 実行サーバから WinRM 疎通を確認
```

---

## 14. トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `No configuration files found` | Working Directory 未設定 | ワークスペース設定で `terraform/ansible-node` を指定する（手順 6.1） |
| `Inappropriate value for attribute "allowed_ssh_source_addresses": list of string required` | 変数の HCL がオフ | 変数編集で **HCL をオン**にし `["x.x.x.x/32"]` と入力する |
| `invalid HCL for variable "allowed_ssh_source_addresses" at 1,1: Invalid number literal` | HCL はオンだが値が `203.0.113.10/32` のように**角かっこ・ダブルクォート無し**で入力されている | `["203.0.113.10/32"]` と入力する（HCL オン時は値を HCL 式として解釈するため、IP をそのまま書くと数値リテラルと見なされる） |
| `SSH 公開鍵が解決できません` | `ssh_public_key` 未設定 | 公開鍵の**内容**を Terraform variable に設定する（手順 6.3） |
| `building AzureRM Client: ... could not configure AzureCli Authorizer` | Azure 認証情報が未設定 | Environment variables 4 件を設定する（手順 6.2） |
| `Warning: Value for undeclared variable ... "ARM_TENANT_ID"`（plan 自体は成功） | `ARM_*` を **Terraform variable** カテゴリで登録している | 警告自体は無害だが、その値は Azure 認証に使われない。4 件を **Environment variable** として登録し直し、Terraform variable 側は削除する（手順 6.2） |
| `Authorization failed` / `AuthorizationFailed` | SP の権限不足 | SP に対象サブスクリプションの **Contributor** を付与する |
| `Windows サーバへは Ansible 実行サーバの Public IP から接続する構成です` | `create_public_ip = false` かつ `create_windows_server = true` | `create_public_ip = true` にする（別 VNet の Windows へ到達できないため） |
| Windows VM の apply が `The requested size ... is not available` | 指定リージョンで `windows_vm_size` が使えない | `az vm list-skus -l japaneast --size Standard_B --output table` で利用可能なサイズを確認して変更する |
| Windows VM の apply が `The platform image ... is not available` | `windows_source_image` の SKU がサブスクリプションで使えない | `az vm image list --publisher MicrosoftWindowsServer --offer WindowsServer --all -o table` で確認し、`2022-datacenter-azure-edition` 等に変更する |
| Public IP の apply が `DomainNameLabelReserved: ... is invalid. The name itself or part of the name is a reserved word such as a trademark` | DNS ラベルに `windows` などの商標語が含まれている | 既定では `<prefix>-<env>-win-<ランダム>` に短縮済み。独自ラベルを使う場合は `windows_domain_name_label` に商標語（windows / microsoft / azure / xbox 等）を含めない値を指定する |
| Windows VM の apply が `"patch_mode" must always be set to "AutomaticByPlatform" when "source_image_reference" points to a hotpatch enabled image` | `azure-edition` 系イメージはホットパッチ対応のため `patch_mode` の明示が必要 | 既定で `windows_patch_mode = "AutomaticByPlatform"` を設定済み。ホットパッチ非対応イメージに変更した場合のみ `AutomaticByOS` / `Manual` も指定できる |
| Run Command が `VMExtensionProvisioningError` で失敗し、詳細に `The string is missing the terminator: '.` が出る | `bootstrap_winrm.ps1` に非 ASCII 文字（日本語）が含まれている。Run Command は BOM 無しでファイル化するため PowerShell 5.1 が ANSI として読み、文字化けして構文エラーになる | 同スクリプトは **ASCII のみ**で記述する（日本語の説明はドキュメント側に置く）。plan 時に precondition で検出される。確認: `grep -n -P '[^\x00-\x7F]' terraform/scripts/bootstrap_winrm.ps1` |
| Run Command が失敗した状態で残り、再 apply でも同じエラーになる | 拡張機能が失敗状態のまま VM に残っている | Azure Portal の VM → 「実行コマンド」で `winrm-bootstrap` を削除してから再 apply する |
| Public IP の apply が `DomainNameLabel ... is already taken` | 同じリージョンで DNS ラベルが重複している | `prefix` / `env` を変えるか、`windows_domain_name_label` を明示指定する |
| SSH がタイムアウトする | 接続元 IP が NSG 許可範囲外 | `curl -s https://ifconfig.me` で現在の IP を確認し変数を更新して apply |
| SSH が `Permission denied (publickey)` | 登録した公開鍵と手元の秘密鍵が不一致 | `ssh -i ~/.ssh/id_ed25519 azureuser@<FQDN>` で鍵を明示する |
| `ansible` コマンドが無い | cloud-init 未完了 | `cloud-init status --wait` で完了を待つ |
| VM が停止している | 自動シャットダウン（毎日 21:00 JST） | Azure Portal で起動する。不要なら `enable_auto_shutdown = false` |
| `nc -vz <Windows IP> 5986` がタイムアウト | Ansible 実行サーバを作り直して Public IP が変わった | 再度 apply して NSG を更新する（同一構成内なら自動追従する） |
| `win_ping` が `Connection refused` | WinRM 未有効化 | Run Command が失敗している。Azure Portal の VM → 「実行コマンド」で `bootstrap_winrm.ps1` を再実行する（手順 9） |
| `win_ping` が `the specified credentials were rejected` | `vault.yml` の値が Terraform 側と不一致 | `windows_admin_password_generated` の値を `vault_local_admin_password` に設定する（手順 11.2） |
| `win_ping` が `certificate verify failed` | 証明書検証が有効 | `inventory/group_vars/windows.yml` の `ansible_winrm_server_cert_validation: ignore` を確認する |
| `win_ping` で名前解決に失敗する | `ansible_host` が private IP のまま | Windows の **Public IP** に変更する（手順 11.3） |

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
make help              # 使えるターゲット一覧
make plan              # 変更内容の確認
make apply             # 構築
make ssh               # Ansible 実行サーバへ SSH
make upload            # Playbook 転送
make winpass           # Windows のパスワード表示
make rdp               # Windows への RDP コマンド表示
make wincheck          # WinRM 疎通確認
make rebuild           # destroy → apply
make destroy           # 削除
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

## 付録 C. 別環境の既存 Windows サーバを対象にする場合

Windows サーバが**既に別環境に存在する**場合は、本手順で Windows を作らず、
その NSG だけを `terraform/windows-nsg` で構成します。
ワークスペースは 2 つになります。

### C-1. ansible-node 側の設定

手順 6.3 の Terraform variables に以下を追加します。

| キー | 値 | HCL |
| --- | --- | --- |
| `create_windows_server` | `false` | |
| `windows_server_public_ips` | `["203.0.113.20/32"]`（対象 Windows の Public IP） | ✅ **オン** |

これで Windows サーバは作成されず、NSG の送信許可（5986）だけが設定されます。

### C-2. Ansible 実行サーバの Public IP を確認する

WinRM の許可元になります。Outputs の `ansible_node_source_cidr`
（例: `203.0.113.11/32`）を控えます。

```bash
terraform -chdir=terraform/ansible-node output -raw ansible_node_source_cidr
```

> この値を明示せず、Azure 上の Public IP リソースから**自動参照**させることもできます
> （`ansible_node_public_ip` を空にする）。Ansible 実行サーバを作り直した際に
> 追従できるため、こちらを推奨します。

### C-3. windows-nsg のワークスペースを作成する

`ansible-node` とは **別ワークスペース**にします（state を分けるため）。

1. **New workspace → Version control workflow** → `ishida-hiro/ansible-test-J32474`
2. **Workspace Name**: `ansible-test-J32474-windows-nsg`（任意）
3. **Working Directory** に `terraform/windows-nsg` を設定
4. **Environment variables** は `ansible-node` と同じ 4 件を設定
   （`ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID`）

### C-4. Terraform variables を設定する

| キー | 値の例 | HCL | 必須 |
| --- | --- | --- | --- |
| `resource_group_name` | `rg-pickles-windows`（Windows サーバの既存 RG） | | ✅ |
| `allowed_rdp_source_addresses` | `["203.0.113.10/32"]` | ✅ **オン** | ✅ |
| `ansible_node_public_ip` | `203.0.113.11/32`（空なら自動参照） | | |
| `location` | `japaneast` | | |
| `network_interface_ids` | `["/subscriptions/.../nic-S-AZR-007"]` | ✅ **オン** | |

`network_interface_ids` を指定すると NSG が各 NIC に自動で関連付きます。
空のままにすると **NSG を作成するだけ**なので、Azure Portal 等で手動関連付けが必要です。

### C-5. apply して許可内容を確認する

**Start new run** → plan 確認 → **Confirm & Apply**。

```bash
az network nsg rule list \
  --nsg-name nsg-pickles-verify-windows \
  --resource-group rg-pickles-windows --output table
```

### C-6. Windows サーバで WinRM を有効化する

運用端末から RDP でログオンし、管理者権限の PowerShell で実行します。

```powershell
.\bootstrap_winrm.ps1        # terraform/scripts/bootstrap_winrm.ps1
```

Azure の Custom Script Extension / 実行コマンド（RunCommand）から実行しても構いません。

### C-7. 削除する場合の順序

**削除は windows-nsg → ansible-node の順**で行います
（windows-nsg が ansible-node の Public IP を参照しているため）。

`windows-nsg` は **既存 RG 内に NSG だけを作る**構成のため、destroy しても
Windows サーバ本体には影響しません（NSG の関連付けが外れます）。

---

## 関連ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [01_構築手順.md](01_構築手順.md) | Windows サーバ（ファイルサーバ）の構築手順 |
| [02_ロール一覧.md](02_ロール一覧.md) | Ansible ロールと設計書の対応表 |
| [03_要確認事項.md](03_要確認事項.md) | 設計書の未確定・矛盾箇所 |
| [../terraform/README.md](../terraform/README.md) | 接続方式の全体像と実行順序 |
| [../terraform/ansible-node/README.md](../terraform/ansible-node/README.md) | Terraform 構成のリファレンス（変数一覧など） |
| [../terraform/windows-nsg/README.md](../terraform/windows-nsg/README.md) | 既存 Windows サーバ用 NSG のリファレンス（付録 C で使用） |
