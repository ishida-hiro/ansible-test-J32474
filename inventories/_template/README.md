# 案件インベントリの雛形

新しい案件を始めるときは、このディレクトリを複製して使います。

```bash
cp -r inventories/_template inventories/<案件名>
```

## 置き場所の考え方

| 置き場所 | 書くもの |
| --- | --- |
| `roles/win_standard/defaults/main.yml` | JBCC 標準値（全案件共通）。**案件作業では変更しない** |
| `roles/<ロール>/defaults/main.yml` | そのロールだけが使う標準値。**案件作業では変更しない** |
| `inventories/<案件>/group_vars/all/main.yml` | 案件全体で標準と違う値（ドメイン名など） |
| `inventories/<案件>/group_vars/<グループ>.yml` | 用途ごとの値（役割と機能、ローカルユーザなど） |
| `inventories/<案件>/host_vars/<ホスト>/main.yml` | ホスト固有の値（コンピュータ名、OS 名、ディスク） |
| `inventories/<案件>/host_vars/<ホスト>/connection.yml` | 接続先 IP（git 管理外） |
| `inventories/<案件>/group_vars/all/vault.yml` | パスワード（git 管理外・ansible-vault で暗号化） |

**標準と同じ値は案件側に書きません。** 案件側のファイルが「標準との差分の一覧」になり、
どこが案件固有かが一目で分かるようにするためです。

変数で表現できない差分（ロールの処理そのものを変える必要があるもの）が出たら、
案件側で回避せず、ロールを変数化して標準に取り込むかどうかを検討します。

## 手順

1. `hosts.yml` に設計書のサーバ一覧を書く（グループ名は変えない）
2. `host_vars/NEW-HOST-01/` をホスト名に合わせて改名・複製する
3. `connection.yml.example` と `vault.yml.example` を `.example` なしで複製して値を入れる
4. 設計書と標準値を突き合わせ、違う値だけを `group_vars` / `host_vars` に書く
5. 値の確認: `ansible-inventory -i inventories/<案件名>/hosts.yml --host <ホスト名>`
6. 実行: `ansible-playbook playbooks/site.yml -i inventories/<案件名>/hosts.yml --ask-vault-pass`
