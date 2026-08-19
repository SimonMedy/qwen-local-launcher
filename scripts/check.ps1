#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @(
    (Join-Path $root 'scripts\tray-launcher.ps1'),
    (Join-Path $root 'scripts\check.ps1')
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error "$file:$($_.Extent.StartLineNumber): $($_.Message)" }
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

Write-Host 'Static checks passed.'
