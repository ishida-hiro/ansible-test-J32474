<#
================================================================================
 bootstrap_winrm.ps1
   Enables WinRM over HTTPS (5986) so that Ansible can connect to this server.

   How to run (any of the following):
     A) Automatically, via azurerm_virtual_machine_run_command
        (terraform/ansible-node/windows.tf -- this is the default)
     B) Azure portal -> Virtual machine -> Operations -> Run command
     C) Log on with RDP and run it from an elevated PowerShell prompt

   NOTE: This script creates a SELF-SIGNED certificate.
   To validate the certificate instead, replace it with a proper one and set
   ansible_winrm_server_cert_validation to "validate" in
   inventory/group_vars/windows.yml.

 ------------------------------------------------------------------------------
 *** KEEP THIS FILE ASCII-ONLY. DO NOT ADD JAPANESE OR OTHER NON-ASCII TEXT. ***

   Azure Run Command writes this script to a file WITHOUT a BOM, and Windows
   PowerShell 5.1 then reads that file as ANSI (not UTF-8). Any multi-byte
   character is corrupted on the way in, which breaks string terminators and
   makes the whole script fail to parse:

     Script_winrm-bootstrap_0.ps1:66 char:96
     The string is missing the terminator: '.
     FullyQualifiedErrorId : TerminatorExpectedAtEndOfString

   Japanese explanations belong in the docs, not in this file.
   See terraform/README.md and the doc 04 under docs/.
================================================================================
#>
[CmdletBinding()]
param(
    [int]$Port = 5986,
    [string]$CertSubject = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

Write-Host "=== Starting the WinRM service ==="
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

Write-Host "=== Creating a self-signed certificate (CN=$CertSubject) ==="
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq "CN=$CertSubject" -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName $CertSubject `
                -CertStoreLocation Cert:\LocalMachine\My `
                -NotAfter (Get-Date).AddYears(5)
    Write-Host "Created certificate: $($cert.Thumbprint)"
} else {
    Write-Host "Reusing existing certificate: $($cert.Thumbprint)"
}

Write-Host "=== Configuring the HTTPS listener (Port=$Port) ==="
$listener = winrm enumerate winrm/config/Listener 2>$null | Select-String 'Transport = HTTPS'
if ($listener) {
    winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null | Out-Null
}
New-WSManInstance -ResourceURI winrm/config/Listener `
    -SelectorSet @{ Address = '*'; Transport = 'HTTPS' } `
    -ValueSet @{ Hostname = $CertSubject; CertificateThumbprint = $cert.Thumbprint; Port = $Port } | Out-Null

Write-Host "=== Configuring authentication and timeouts ==="
winrm set winrm/config/service/auth '@{Negotiate="true"}'          | Out-Null
winrm set winrm/config/service      '@{AllowUnencrypted="false"}'  | Out-Null
winrm set winrm/config/winrs        '@{MaxMemoryPerShellMB="2048"}' | Out-Null
winrm set winrm/config              '@{MaxTimeoutms="1800000"}'     | Out-Null

Write-Host "=== Adding the firewall rule ==="
# Only needed while building. Once done, restrict 5986 at the NSG (design 1.10).
if (-not (Get-NetFirewallRule -Name 'WinRM-HTTPS-In' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'WinRM-HTTPS-In' -DisplayName 'Windows Remote Management (HTTPS-In)' `
        -Enabled True -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
}

Write-Host "=== Resulting configuration ==="
winrm enumerate winrm/config/Listener
Write-Host "Done. Verify connectivity from Ansible with win_ping."
