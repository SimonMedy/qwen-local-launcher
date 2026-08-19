#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$createdNew = $false
$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

try {
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
