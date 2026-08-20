#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = @(
    (Join-Path $root 'scripts\tray-bootstrap.ps1'),
    (Join-Path $root 'scripts\tray-theme.ps1'),
    (Join-Path $root 'scripts\tray-icon.ps1'),
    (Join-Path $root 'scripts\tray-app.ps1'),
    (Join-Path $root 'scripts\runtime-diagnostics.ps1'),
    (Join-Path $root 'scripts\tray-launcher.ps1'),
    (Join-Path $root 'scripts\configure-llama.ps1'),
    (Join-Path $root 'scripts\build-launcher.ps1'),
    (Join-Path $root 'scripts\check.ps1')
)
foreach ($file in $files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error "${file}:$($_.Extent.StartLineNumber): $($_.Message)" } }
}

$config = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\profiles.psd1')
foreach ($name in @('Stable 160k','MTP 128k','Stable 180k')) { if (-not $config.Profiles.Contains($name)) { throw "Missing required profile: $name" } }
function Assert-FlagValue {
    param([object[]]$ProfileArgs,[string]$Flag,[string]$Expected,[string]$Profile)
    $index = [Array]::IndexOf($ProfileArgs,$Flag)
    if ($index -lt 0 -or $index + 1 -ge $ProfileArgs.Count -or [string]$ProfileArgs[$index + 1] -ne $Expected) { throw "Profile '$Profile' must contain $Flag $Expected." }
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
if (@($config.Profiles['MTP 128k']) -notcontains '--no-mmproj-offload') { throw 'MTP 128k must keep multimodal enabled while disabling mmproj GPU offload.' }
if (@($config.Profiles['MTP 128k']) -contains '--spec-draft-p-min') { throw 'MTP 128k must not use the old --spec-draft-p-min setting.' }

$tray = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-app.ps1') -Raw
foreach ($needle in @('Get-ProcessTreeIds','Runtime diagnostics','ProfileOrder','--metrics','QwenPopupForm')) { if ($tray -notmatch [regex]::Escape($needle)) { throw "Tray missing expected behavior: $needle" } }
if ($tray -match 'ContextMenuStrip|ToolStripMenuItem') { throw 'Tray must use the custom borderless popup instead of ToolStrip menus.' }
$theme = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-theme.ps1') -Raw
foreach ($needle in @('QwenPopupForm','QwenMenuButton','TextRenderer','DwmSetWindowAttribute')) { if ($theme -notmatch [regex]::Escape($needle)) { throw "Theme missing expected popup primitive: $needle" } }
if ($theme -match '[^\x00-\x7F]') { throw 'Tray theme must remain ASCII-only for Windows PowerShell 5.1 compatibility.' }
$diag = Get-Content -LiteralPath (Join-Path $root 'scripts\runtime-diagnostics.ps1') -Raw
foreach ($needle in @('/health','/slots','/metrics','/v1/models','GPUProcessMemory','CommittedBytes','KV buffer size','compute buffer size','offload','speculat')) { if ($diag -notmatch [regex]::Escape($needle)) { throw "Diagnostics missing expected signal: $needle" } }
if ($diag -match '[^\x00-\x7F]') { throw 'Runtime diagnostics must remain ASCII-only for Windows PowerShell 5.1 compatibility.' }
if ($tray -match '[^\x00-\x7F]') { throw 'Tray app must remain ASCII-only for Windows PowerShell 5.1 compatibility.' }

. (Join-Path $root 'scripts\tray-theme.ps1')
$smoke = New-QwenPopupForm
$smokeButton = New-QwenPopupButton 'Smoke test'
$smoke.Controls.Add($smokeButton)
$smoke.Dispose()

$iconPath = Join-Path $root 'assets\QwenLocalLauncher.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'Missing versioned assets/QwenLocalLauncher.ico.' }
$builder = Get-Content -LiteralPath (Join-Path $root 'scripts\build-launcher.ps1') -Raw
if ($builder -match 'Convert-PngToMultiSizeIcon') { throw 'Launcher build must not regenerate the versioned ICO.' }
if ($builder -notmatch '/win32icon:') { throw 'Launcher build must embed the versioned ICO.' }
$setup = Get-Content -LiteralPath (Join-Path $root 'setup.cmd') -Raw
if ($setup -notmatch 'dist\\Qwen Local Launcher\.exe') { throw 'Setup must launch the executable from dist.' }
Write-Host 'Static checks passed.'
