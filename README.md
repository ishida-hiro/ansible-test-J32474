# ansible-windows-build

**sample_Windows詳細設計書.xlsx**（シート「1.概要」「8.ファイルサーバ」）に基づく
Windows Server 構築自動化 (Ansible)

Azure 上の Windows Server に対し、OS 初期設定・ドメイン参加・役割固有設定・
設定値検証までを自動化します。

> **改訂について**
> 旧版はシート「2.AD(1号機)」＝ **ADサーバ（ドメインコントローラ）** を対象としていました。
> 本版は新しい設計書に合わせ、シート「8.ファイルサーバ」＝ **概要 No.7 のファイルサーバ**
> を対象に作り直しています。差分は
> [docs/01_構築手順.md「7. 前版（ADサーバ版）からの変更点」](docs/01_構築手順.md#7-前版adサーバ版からの変更点) を参照してください。

## 今回のスコープ

今回の Ansible 初期構築は **検証機 1 台（`Ansible-TEST-FS`）** が対象です。
以下は **対象外** としています（詳細は [docs/01_構築手順.md](docs/01_構築手順.md)「0. 今回のスコープ」）。

- ドメイン参加（`enable_domain_join: false`）
- タスクスケジューラ「SHM商品マスター更新」（起動日時が過去日時のため / `skip: true`）
- ADサーバ・他メンバーサーバ（概要 No.1〜6）の構築

実施する内容（概要 No.7 / シート8）:

- OS 初期設定（ディスク / IPv6 無効化 / 日本語・タイムゾーン / RDP / ファイアウォール無効 /
  Defender 無効化 / UAC 無効化 / イベントログ / サービス / Windows Update）
- 役割と機能: **IIS(Web + FTP) / ファイルサーバ / FSRM / ASP.NET 4.8 / RSAT(FSRM)**
- ローカルユーザ: `kansai` / FTP 認証ユーザ `docways` / `NPJS`
- **FTP サイト 2 件**（`D:\POD` / `D:\NPJS`、ともに `*:21` 基本認証、ログ日次ロールオーバー）
- **タスクスケジューラ 7 件**（設計書 8 件のうち 1 件は上記のとおり対象外）
- 設定値検証・証跡取得

設計書は**サンプル版**でホスト名・コンピュータ名・ローカルユーザ名・FTP サイト名が
マスクされているため、概要シートの記載から補完しています。
IP アドレス・ディスク構成・パスワードは **仮値** です。

```
ansible-windows-build/
├── ansible.cfg
├── requirements.yml            # 依存コレクション
├── inventory/
│   ├── test.yml                # ★今回の対象（Ansible-TEST-FS 1台）／既定インベントリ
│   ├── hosts.yml               # 本番相当の7台構成（-i で指定）
│   ├── group_vars/             # 設計書「1.概要」の共通パラメータ
│   │   └── fileserver.yml      # ★今回の設計対象（シート「8.ファイルサーバ」）
│   └── host_vars/              # ホスト個別パラメータ
├── roles/                      # 14 ロール（docs/02_ロール一覧.md 参照）
├── playbooks/
│   ├── site.yml                # 一括実行
│   ├── 01_os_initial.yml       # OS 初期設定
│   ├── 02_domain.yml           # ドメイン参加・時刻同期
│   ├── 03_role_setup.yml       # FTP / タスクスケジューラ
│   ├── 99_verify.yml           # 設定値検証・証跡取得
│   └── win_update.yml          # 更新プログラム適用のみ（運用時用）
├── terraform/
│   ├── ansible-node/           # Ansible 実行用サーバを払い出す Terraform（検証用・専用RG）
│   └── scripts/                # WinRM 有効化スクリプト
├── docs/
│   ├── 01_構築手順.md / .docx          # 検討用に Word 版も同梱
│   ├── 02_ロール一覧.md / .xlsx        # 検討用に Excel 版も同梱
│   └── 03_要確認事項.md / .xlsx        # ★ 実行前に必ずご確認ください
├── evidence/                   # 証跡出力先（git 管理外）
└── logs/                       # 実行ログ（git 管理外）
```

## クイックスタート

```bash
# 1. 依存コレクションの導入
ansible-galaxy collection install -r requirements.yml

# 2. 対象サーバに D: 用データディスクをアタッチしておく（FTP の物理パスが D:\ 配下のため）

# 3. 対象サーバで WinRM を有効化（1回だけ / RDP または RunCommand で実行）
#    terraform/scripts/bootstrap_winrm.ps1

# 4. 接続先と認証情報を実機に合わせる（いずれも仮値が入っています）
vi inventory/test.yml                          # ansible_host を実機 IP に
vi inventory/group_vars/all/vault.yml          # 仮パスワードを実機の値に

# 5. 接続確認
ansible windows -m ansible.windows.win_ping

# 6. 構築
ansible-playbook playbooks/site.yml
```

詳細は [docs/01_構築手順.md](docs/01_構築手順.md) を参照してください。

## 実行前の注意

設計書に **記載が無い／マスクされている／矛盾している** 項目があります。
A 区分（ホスト名・IP アドレス・パスワード・ドメイン参加・タスク起動日時・
ローカルユーザ名・FTP サイト名）は今回のスコープに合わせて仮値／対象外としていますが、
**B 区分は未解決**です。

- B-1 仮想メモリの記載矛盾（既定では設定変更しません）
- B-2 ファイアウォールの記載矛盾（本文に従い無効化）
- B-3 「自動更新を構成する = 無効」のレジストリ解釈
- B-6 Defender の記載矛盾（リアルタイム保護 有効 vs GPO で無効化）
- B-7 IIS の役割がベンダー様対応範囲か
- B-8 FSRM の具体的な設定内容が未記載
- B-9 SMB 共有フォルダの設定が未記載

本番構築の前に [docs/03_要確認事項.md](docs/03_要確認事項.md) をご確認ください。

## ドキュメントの管理方針

**Markdown を正（マスタ）** とします。`docs/` の `.docx` / `.xlsx` は
検討・レビュー時に見やすくするために Markdown から生成したスナップショットです。
内容を更新する際は `.md` を編集し、必要に応じて Office 版を作り直してください。
