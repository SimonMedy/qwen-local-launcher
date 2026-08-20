#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @(
    (Join-Path $root 'scripts\tray-bootstrap.ps1'),
    (Join-Path $root 'scripts\tray-theme.ps1'),
    (Join-Path $root 'scripts\tray-icon.ps1'),
    (Join-Path $root 'scripts\tray-app.ps1'),
    (Join-Path $root 'scripts\tray-launcher.ps1'),
    (Join-Path $root 'scripts\configure-llama.ps1'),
    (Join-Path $root 'scripts\build-launcher.ps1'),
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
foreach ($name in @('Stable 160k','MTP 128k','Stable 180k')) {
    if (-not $config.Profiles.Contains($name)) { throw "Missing required profile: $name" }
}

function Assert-FlagValue {
    param([object[]]$ProfileArgs, [string]$Flag, [string]$Expected, [string]$Profile)
    $index = [Array]::IndexOf($ProfileArgs, $Flag)
    if ($index -lt 0 -or $index + 1 -ge $ProfileArgs.Count -or [string]$ProfileArgs[$index + 1] -ne $Expected) {
        throw "Profile '$Profile' must contain $Flag $Expected."
    }
}

foreach ($name in $config.Profiles.Keys) {
    $profileArgs = @($config.Profiles[$name])
    if ($profileArgs -contains '--no-mmproj') { throw "Profile '$name' disables multimodal support." }
    if ($profileArgs -contains '--fit-target') { throw "Profile '$name' must not use --fit-target." }
    Assert-FlagValue $profileArgs '-hf' 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL' $name
    Assert-FlagValue $profileArgs '-ngl' 'auto' $name
    Assert-FlagValue $profileArgs '--cache-type-k' 'q8_0' $name
    Assert-FlagValue $profileArgs '--cache-type-v' 'q4_0' $name
    Assert-FlagValue $profileArgs '--flash-attn' 'on' $name
    Assert-FlagValue $profileArgs '-np' '1' $name
    Assert-FlagValue $profileArgs '--cache-reuse' '256' $name
    Assert-FlagValue $profileArgs '--cache-ram' '4096' $name
    Assert-FlagValue $profileArgs '-t' '8' $name
    Assert-FlagValue $profileArgs '-tb' '16' $name
    Assert-FlagValue $profileArgs '--temp' '1.0' $name
    Assert-FlagValue $profileArgs '--top-p' '0.95' $name
    Assert-FlagValue $profileArgs '--top-k' '20' $name
    Assert-FlagValue $profileArgs '--min-p' '0.0' $name
    Assert-FlagValue $profileArgs '--presence-penalty' '0.0' $name
    Assert-FlagValue $profileArgs '--repeat-penalty' '1.0' $name
}

Assert-FlagValue @($config.Profiles['Stable 160k']) '-c' '160000' 'Stable 160k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '-c' '131072' 'MTP 128k'
Assert-FlagValue @($config.Profiles['Stable 180k']) '-c' '180000' 'Stable 180k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '--spec-type' 'draft-mtp' 'MTP 128k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '--spec-draft-n-max' '2' 'MTP 128k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '--spec-draft-type-k' 'q4_0' 'MTP 128k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '--spec-draft-type-v' 'q4_0' 'MTP 128k'
if (@($config.Profiles['MTP 128k']) -contains '--spec-draft-p-min') { throw 'MTP 128k must not use the old --spec-draft-p-min setting.' }

$iconPath = Join-Path $root 'assets\QwenLocalLauncher.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'Missing versioned assets/QwenLocalLauncher.ico.' }
$gitignore = Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw
if ($gitignore -match 'assets/QwenLocalLauncher\.ico') { throw 'The final ICO must be versioned, not ignored.' }

$bootstrap = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-bootstrap.ps1') -Raw
if ($bootstrap -notmatch 'QwenLocalLauncher\.ico') { throw 'Tray bootstrap must use the versioned ICO directly.' }

$trayIcon = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-icon.ps1') -Raw
if ($trayIcon -notmatch 'Register-QwenTrayIcon') { throw 'Tray icon integration is missing.' }
if ($trayIcon -match 'ChangeExtension') { throw 'Tray icon must not derive an ICO dynamically from the PNG.' }

$builder = Get-Content -LiteralPath (Join-Path $root 'scripts\build-launcher.ps1') -Raw
if ($builder -match 'Convert-PngToMultiSizeIcon') { throw 'Launcher build must not regenerate the versioned ICO.' }
if ($builder -notmatch 'QwenLocalLauncher\.ico') { throw 'Launcher build must use the versioned ICO.' }
if ($builder -notmatch '/win32icon:') { throw 'Launcher build must embed the versioned ICO.' }
if ($builder -notmatch 'Qwen Local Launcher\.lnk') { throw 'Build script must create Windows shortcuts.' }

$source = Get-Content -LiteralPath (Join-Path $root 'launcher\QwenLocalLauncher.cs') -Raw
if ($source -notmatch 'Directory\.GetParent') { throw 'Launcher in dist must resolve the project root via its parent directory.' }

$setup = Get-Content -LiteralPath (Join-Path $root 'setup.cmd') -Raw
if ($setup -notmatch 'dist\\Qwen Local Launcher\.exe') { throw 'Setup must launch the executable from dist.' }

Write-Host 'Static checks passed.'
