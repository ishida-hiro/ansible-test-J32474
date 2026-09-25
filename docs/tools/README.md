# ドキュメント生成ツール

`docs/` の `.docx` / `.xlsx` は **Markdown（正）から生成したスナップショット**です。
`.md` を更新したら、リポジトリのルートで以下を実行して作り直してください。

```bash
python3 docs/tools/md2docx.py docs/01_構築手順.md docs/01_構築手順.docx
python3 docs/tools/md2docx.py docs/04_Ansible実行サーバ構築手順.md docs/04_Ansible実行サーバ構築手順.docx
python3 docs/tools/md2docx.py docs/05_検証結果まとめ.md docs/05_検証結果まとめ.docx
python3 docs/tools/md2xlsx.py      # 02 / 03 の .xlsx を再生成
python3 docs/tools/make_record_template.py   # 06 検証記録様式（空の様式）を再生成
```

- `md2docx.py` … Markdown を WordprocessingML(.docx) に変換（外部ライブラリ不要）
- `md2xlsx.py` … `docs/02_ロール一覧.md` / `docs/03_要確認事項.md` の表を .xlsx 化（要 `openpyxl`）
- `make_record_template.py` … 検証記録の空の様式を生成。「記入要領」シートは `docs/06_検証記録様式.md` の表から作る（要 `openpyxl`）

`md2xlsx.py` は 02 / 03 の両方を作り直します。`.md` を変更していない方は
`git checkout` で戻し、差分を汚さないようにしてください。

対応する Markdown 記法は見出し・表・箇条書き・番号付きリスト・コードブロック・
引用・水平線・`**太字**`・`` `コード` `` です。
