#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$createdNew = $false
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

try {
    . (Join-Path $PSScriptRoot 'tray-theme.ps1')
    Register-QwenTrayTheme

    . (Join-Path $PSScriptRoot 'tray-icon.ps1')
    Register-QwenTrayIcon -IconPath (Join-Path $root 'assets\QwenLocalLauncher.ico')

    . (Join-Path $PSScriptRoot 'tray-app.ps1')
} catch {
    $message = $_ | Out-String
    $logPath = Join-Path $logDir 'tray-startup-error.log'
    $message | Set-Content -LiteralPath $logPath -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show(
        "Qwen Local Launcher could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails were written to:`r`n$logPath",
        'Qwen Local Launcher - Startup Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
