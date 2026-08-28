# ============================================================================
# Ansible 実行用サーバ（検証環境）操作用 Makefile
#   作り直しを簡単にするためのショートカット。
#   前提: az login 済み / terraform.tfvars 作成済み
# ============================================================================
TF ?= terraform

.PHONY: help init fmt validate plan apply destroy rebuild recreate-vm recreate-windows \
        ssh upload status output rdp winpass wincheck

help:                ## 使い方を表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init:                ## 初期化（プロバイダ取得）
	$(TF) init

fmt:                 ## フォーマット
	$(TF) fmt -recursive

validate:            ## 構文チェック
	$(TF) validate

plan:                ## 変更内容を確認する
	$(TF) plan

apply:               ## 構築する
	$(TF) apply

destroy:             ## リソースグループごと削除する
	$(TF) destroy

rebuild:             ## 全削除 → 再構築（検証のやり直し）
	$(TF) destroy -auto-approve
	$(TF) apply -auto-approve

recreate-vm:         ## Ansible 実行サーバの VM だけ作り直す（ネットワークは維持）
	$(TF) apply -replace=azurerm_linux_virtual_machine.this

recreate-windows:    ## Windows サーバの VM だけ作り直す（ネットワークは維持）
	$(TF) apply -replace='azurerm_windows_virtual_machine.this[0]'

ssh:                 ## 構築したサーバへ SSH する
	@$$($(TF) output -raw ssh_command)

upload:              ## Playbook 一式を転送する
	@$$($(TF) output -raw upload_playbook_command)

status:              ## 初期セットアップの完了確認コマンドを表示する
	@echo "$$($(TF) output -raw ssh_command) '$$($(TF) output -raw setup_status_command)'"

output:              ## 出力値を表示する
	$(TF) output

rdp:                 ## Windows サーバへの RDP 接続コマンドを表示する
	@$(TF) output -raw windows_rdp_command; echo

winpass:             ## Windows のローカル管理者パスワードを表示する
	@$(TF) output -raw windows_admin_password; echo

wincheck:            ## Ansible 実行サーバから Windows の WinRM(5986) 疎通を確認する
	@$$($(TF) output -raw ssh_command) "$$($(TF) output -raw windows_winrm_check_command)"
