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
    (Join-Path $root 'scripts\build-launcher.ps1')
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        Write-Error "$file :$($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}

$config = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\profiles.psd1')
if ($config.DefaultProfile -ne 'Stable 160k') { throw 'Stable 160k must remain the default profile.' }
if ($config.Profiles.Count -ne 2) { throw 'Exactly two benchmark profiles are expected.' }
if (-not $config.Profiles.Contains('Stable 160k')) { throw 'Missing Stable 160k profile.' }
if (-not $config.Profiles.Contains('MTP Tuned')) { throw 'Missing MTP Tuned profile.' }
if (@($config.ProfileOrder) -join '|' -ne 'Stable 160k|MTP Tuned') { throw 'ProfileOrder must be Stable 160k then MTP Tuned.' }

function Assert-FlagValue {
    param([object[]]$Args, [string]$Flag, [string]$Expected, [string]$Profile)
    $index = [Array]::IndexOf($Args, $Flag)
    if ($index -lt 0 -or $index + 1 -ge $Args.Count -or [string]$Args[$index + 1] -ne $Expected) {
        throw "Profile '$Profile' must contain $Flag $Expected."
    }
}

function Assert-Flag {
    param([object[]]$Args, [string]$Flag, [string]$Profile)
    if ($Args -notcontains $Flag) { throw "Profile '$Profile' must contain $Flag." }
}

function Assert-NoFlag {
    param([object[]]$Args, [string]$Flag, [string]$Profile)
    if ($Args -contains $Flag) { throw "Profile '$Profile' must not contain $Flag." }
}

$stable = @($config.Profiles['Stable 160k'])
Assert-FlagValue $stable '-hf' 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL' 'Stable 160k'
Assert-FlagValue $stable '-c' '50000' 'Stable 160k'
Assert-FlagValue $stable '-ngl' 'auto' 'Stable 160k'
Assert-FlagValue $stable '--cache-type-k' 'q8_0' 'Stable 160k'
Assert-FlagValue $stable '--cache-type-v' 'q4_0' 'Stable 160k'
Assert-FlagValue $stable '--flash-attn' 'on' 'Stable 160k'
Assert-FlagValue $stable '--image-min-tokens' '1024' 'Stable 160k'
Assert-FlagValue $stable '-np' '1' 'Stable 160k'
Assert-FlagValue $stable '--cache-ram' '2048' 'Stable 160k'
Assert-FlagValue $stable '-b' '1024' 'Stable 160k'
Assert-FlagValue $stable '-ub' '512' 'Stable 160k'
Assert-FlagValue $stable '-t' '8' 'Stable 160k'
Assert-FlagValue $stable '-tb' '16' 'Stable 160k'
Assert-FlagValue $stable '--temp' '1.0' 'Stable 160k'
Assert-FlagValue $stable '--top-p' '0.95' 'Stable 160k'
Assert-FlagValue $stable '--top-k' '20' 'Stable 160k'
Assert-FlagValue $stable '--min-p' '0.0' 'Stable 160k'
Assert-FlagValue $stable '--presence-penalty' '0.0' 'Stable 160k'
Assert-FlagValue $stable '--repeat-penalty' '1.0' 'Stable 160k'
foreach ($flag in @('--no-mmproj-offload','--reasoning-preserve')) { Assert-Flag $stable $flag 'Stable 160k' }
foreach ($flag in @('--no-mmproj','--cache-reuse','--fit-ctx','--fit-target','-lv')) { Assert-NoFlag $stable $flag 'Stable 160k' }

$mtp = @($config.Profiles['MTP Tuned'])
Assert-FlagValue $mtp '-hf' 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL' 'MTP Tuned'
Assert-FlagValue $mtp '-c' '50000' 'MTP Tuned'
Assert-FlagValue $mtp '-ngl' 'auto' 'MTP Tuned'
Assert-FlagValue $mtp '--fit-target' '512' 'MTP Tuned'
Assert-FlagValue $mtp '--cache-type-k' 'q5_1' 'MTP Tuned'
Assert-FlagValue $mtp '--cache-type-v' 'q5_1' 'MTP Tuned'
Assert-FlagValue $mtp '--flash-attn' 'on' 'MTP Tuned'
Assert-FlagValue $mtp '--image-min-tokens' '1024' 'MTP Tuned'
Assert-FlagValue $mtp '-np' '1' 'MTP Tuned'
Assert-FlagValue $mtp '-b' '1024' 'MTP Tuned'
Assert-FlagValue $mtp '-ub' '128' 'MTP Tuned'
Assert-FlagValue $mtp '--cache-ram' '2048' 'MTP Tuned'
Assert-FlagValue $mtp '--ctx-checkpoints' '64' 'MTP Tuned'
Assert-FlagValue $mtp '-t' '8' 'MTP Tuned'
Assert-FlagValue $mtp '-tb' '16' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-type' 'draft-mtp,ngram-mod' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-draft-n-max' '2' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-draft-p-min' '0.82' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-draft-type-k' 'q4_0' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-draft-type-v' 'q4_0' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-ngram-mod-n-match' '24' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-ngram-mod-n-min' '48' 'MTP Tuned'
Assert-FlagValue $mtp '--spec-ngram-mod-n-max' '64' 'MTP Tuned'
Assert-FlagValue $mtp '--temp' '1.0' 'MTP Tuned'
Assert-FlagValue $mtp '--top-p' '0.95' 'MTP Tuned'
Assert-FlagValue $mtp '--top-k' '20' 'MTP Tuned'
Assert-FlagValue $mtp '--min-p' '0.0' 'MTP Tuned'
Assert-FlagValue $mtp '--presence-penalty' '0.0' 'MTP Tuned'
Assert-FlagValue $mtp '--repeat-penalty' '1.0' 'MTP Tuned'
foreach ($flag in @('--no-mmproj-offload','--reasoning-preserve')) { Assert-Flag $mtp $flag 'MTP Tuned' }
foreach ($flag in @('--no-mmproj','--cache-reuse','--fit-ctx','-lv')) { Assert-NoFlag $mtp $flag 'MTP Tuned' }

$bootstrap = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-bootstrap.ps1') -Raw
$tray = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-app.ps1') -Raw
$iconScript = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-icon.ps1') -Raw
$diagPath = Join-Path $root 'scripts\runtime-diagnostics.ps1'
$diag = Get-Content -LiteralPath $diagPath -Raw

if ($bootstrap -notmatch 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE') { throw 'Bootstrap must keep the Windows Job Object.' }
if ($tray -match 'ContextMenuStrip|ToolStripMenuItem') { throw 'Tray must use the custom popup.' }
if ($iconScript -match 'Procesps') { throw 'tray-icon contains the invalid Procesps typo.' }
foreach ($needle in @('/slots','/metrics','GPUProcessMemory','Requested context','GPU Layers','mmproj backend','SelfTest')) {
    if ($diag -notmatch [regex]::Escape($needle)) { throw "Diagnostics missing expected signal: $needle" }
}
foreach ($text in @($bootstrap,$tray,$iconScript,$diag)) {
    if ($text -match '[^\x00-\x7F]') { throw 'Runtime scripts must remain ASCII-only.' }
}

. (Join-Path $root 'scripts\tray-theme.ps1')
$smoke = New-QwenPopupForm
$smokeButton = New-QwenPopupButton 'Smoke test'
$smoke.Controls.Add($smokeButton)
$smoke.Dispose()

$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    $testCulture = [Globalization.CultureInfo]::InvariantCulture.Clone()
    $testCulture.NumberFormat.NumberGroupSeparator = ''
    $testCulture.NumberFormat.NumberDecimalSeparator = '.'
    [Threading.Thread]::CurrentThread.CurrentCulture = $testCulture
    & $diagPath -Root $root -SelfTest
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
}

$iconPath = Join-Path $root 'assets\QwenLocalLauncher.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'Missing versioned ICO.' }
$builder = Get-Content -LiteralPath (Join-Path $root 'scripts\build-launcher.ps1') -Raw
if ($builder -notmatch '/win32icon:') { throw 'Launcher must embed the versioned ICO.' }

Write-Host 'Static checks passed.'
