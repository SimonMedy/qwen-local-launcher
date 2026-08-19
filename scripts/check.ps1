#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @(
    (Join-Path $root 'scripts\tray-bootstrap.ps1'),
    (Join-Path $root 'scripts\tray-theme.ps1'),
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
if ($launcher -notmatch 'tray-bootstrap\.ps1') { throw 'Hidden launcher must start tray-bootstrap.ps1.' }

$bootstrap = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-bootstrap.ps1') -Raw
if ($bootstrap -notmatch '\$createdNew\s*=\s*\$false') { throw 'Tray bootstrap must initialize the mutex result variable before strict-mode tray startup.' }
if ($bootstrap -notmatch 'tray-app\.ps1') { throw 'Tray bootstrap must invoke tray-app.ps1.' }
if ($bootstrap -notmatch 'tray-theme\.ps1') { throw 'Tray bootstrap must load tray-theme.ps1.' }
if ($bootstrap -notmatch 'Register-QwenTrayTheme') { throw 'Tray bootstrap must register the modern tray theme.' }
if ($bootstrap -notmatch 'tray-startup-error\.log') { throw 'Tray bootstrap must persist startup errors.' }

$theme = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-theme.ps1') -Raw
if ($theme -notmatch 'QwenMenuRenderer') { throw 'Tray theme must define the custom menu renderer.' }
if ($theme -notmatch 'Set-QwenRoundedRegion') { throw 'Tray theme must apply rounded menu corners.' }
if ($theme -notmatch 'Launch at Windows startup') { throw 'Tray theme must use a clear Windows-startup label.' }

$tray = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-app.ps1') -Raw
if ($tray -notmatch 'Change llama\.cpp\.\.\.') { throw 'Tray menu must expose Change llama.cpp...' }
if ($tray -notmatch 'Reload-LauncherConfig') { throw 'Tray app must reload local configuration after changing llama.cpp.' }

$setup = Get-Content -LiteralPath (Join-Path $root 'scripts\configure-llama.ps1') -Raw
if ($setup -match '\.Controls\.Addd\(') { throw 'Setup contains an invalid WinForms Controls.Addd call.' }
if ($setup -notmatch '\.Controls\.Add\(\$save\)') { throw 'Setup must add the Save button to the form.' }

Write-Host 'Static checks passed.'
