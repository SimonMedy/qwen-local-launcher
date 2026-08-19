#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @(
    (Join-Path $root 'scripts\tray-app.ps1'),
    (Join-Path $root 'scripts\tray-launcher.ps1'),
    (Join-Path $root 'scripts\configure-llama.ps1'),
    (Join-Path $root 'scripts\check.ps1')
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error "${file}:$($_.Extent.StartLineNumber): $($_.Message)" }
    }
}

$config = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\profiles.psd1')
$requiredProfiles = @('Stable 160k','MTP 160k','Stable 180k')
foreach ($name in $requiredProfiles) {
    if (-not $config.Profiles.Contains($name)) { throw "Missing required profile: $name" }
}

foreach ($name in $config.Profiles.Keys) {
    $args = @($config.Profiles[$name])
    if ($args -contains '--no-mmproj') { throw "Profile '$name' disables multimodal support." }
    if ($args -notcontains '-hf') { throw "Profile '$name' must specify a Hugging Face model." }
    if ($args -notcontains '-c') { throw "Profile '$name' must specify context size." }
}

$launcher = Get-Content -LiteralPath (Join-Path $root 'scripts\launch-hidden.vbs') -Raw
if ($launcher -notmatch 'configure-llama\.ps1') { throw 'First-run launcher must invoke configure-llama.ps1.' }
if ($launcher -notmatch 'tray-app\.ps1') { throw 'Hidden launcher must start tray-app.ps1.' }

$tray = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-app.ps1') -Raw
if ($tray -notmatch 'Change llama\.cpp\.\.\.') { throw 'Tray menu must expose Change llama.cpp...' }
if ($tray -notmatch 'Reload-LauncherConfig') { throw 'Tray app must reload local configuration after changing llama.cpp.' }

Write-Host 'Static checks passed.'
