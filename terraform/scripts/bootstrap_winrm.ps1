<#
================================================================================
 bootstrap_winrm.ps1
   Ansible から WinRM over HTTPS(5986) で接続できるようにするための初期設定。

   実行方法（いずれか）:
     A) Azure VM の Custom Script Extension で実行する
     B) Azure ポータルの「実行コマンド (RunCommand)」に貼り付けて実行する
     C) RDP でログオンし、管理者権限の PowerShell で実行する

   ※本スクリプトは自己署名証明書を作成する。
     証明書検証を行う場合は正規の証明書に差し替え、
     inventory/group_vars/windows.yml の
     ansible_winrm_server_cert_validation を validate に変更すること。
================================================================================
#>
[CmdletBinding()]
param(
    [int]$Port = 5986,
    [string]$CertSubject = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

Write-Host "=== WinRM サービスを開始する ==="
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

Write-Host "=== 自己署名証明書を作成する (CN=$CertSubject) ==="
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq "CN=$CertSubject" -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName $CertSubject `
                -CertStoreLocation Cert:\LocalMachine\My `
                -NotAfter (Get-Date).AddYears(5)
    Write-Host "証明書を作成しました: $($cert.Thumbprint)"
} else {
    Write-Host "既存の証明書を使用します: $($cert.Thumbprint)"
}

Write-Host "=== HTTPS リスナーを構成する (Port=$Port) ==="
$listener = winrm enumerate winrm/config/Listener 2>$null | Select-String 'Transport = HTTPS'
if ($listener) {
    winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null | Out-Null
}
New-WSManInstance -ResourceURI winrm/config/Listener `
    -SelectorSet @{ Address = '*'; Transport = 'HTTPS' } `
    -ValueSet @{ Hostname = $CertSubject; CertificateThumbprint = $cert.Thumbprint; Port = $Port } | Out-Null

Write-Host "=== 認証方式とタイムアウトを設定する ==="
winrm set winrm/config/service/auth '@{Negotiate="true"}'          | Out-Null
winrm set winrm/config/service      '@{AllowUnencrypted="false"}'  | Out-Null
winrm set winrm/config/winrs        '@{MaxMemoryPerShellMB="2048"}' | Out-Null
winrm set winrm/config              '@{MaxTimeoutms="1800000"}'     | Out-Null

Write-Host "=== ファイアウォール規則を追加する ==="
# 構築中のみ使用する。構築完了後は NSG 側で 5986 を制限すること（設計書 1.10）。
if (-not (Get-NetFirewallRule -Name 'WinRM-HTTPS-In' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'WinRM-HTTPS-In' -DisplayName 'Windows Remote Management (HTTPS-In)' `
        -Enabled True -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
}

Write-Host "=== 構成結果 ==="
winrm enumerate winrm/config/Listener
Write-Host "完了しました。Ansible から win_ping で疎通を確認してください。"
