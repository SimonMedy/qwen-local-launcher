#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreferenc = 'Stop'

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
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -gt 0) {
        foreach ($parseError in $errors) {
            Write-Error "$file :$($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
    }
}

$config = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config\profiles.psd1')

if ($config.Profiles.Count -ne 2) {
    throw 'Exactly two profiles are expected.'
}

foreach ($required in @('Stable 160k', 'MTP 128k')) {
    if (-not $config.Profiles.Contains($required)) {
        throw "Missing profile: $required"
    }
}

if ($config.Profiles.Contains('Stable 180k')) {
    throw 'Stable 180k must be removed.'
}

function Assert-FlagValue {
    param(
        [object[]]$ProfileArgs,
        [string]$Flag,
        [string]$Expected,
        [string]$Profile
    )

    $index = [Array]::IndexOf($ProfileArgs, $Flag)
    if (
        $index -lt 0 -or
        $index + 1 -ge $ProfileArgs.Count -or
        [string]$ProfileArgs[$index + 1] -ne $Expected
    ) {
        throw "Profile '$Profile' must contain $Flag $Expected."
    }
}

$commonPairs = @(
    @('-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL'),
    @('-ngl', 'auto'),
    @('--cache-type-k', 'q8_0'),
    @('--cache-type-v', 'q4_0'),
    @('--flash-attn', 'on'),
    @('--image-min-tokens', '1024'),
    @('-np', '1'),
    @('--cache-ram', '4096'),
    @('-b', '1024'),
    @('-ub', '128'),
    @('-t', '8'),
    @('-tb', '16'),
    @('-lv', '4'),
    @('--temp', '1.0'),
    @('--top-p', '0.95'),
    @('--top-k', '20'),
    @('--min-p', '0.0'),
    @('--presence-penalty', '0.0'),
    @('--repeat-penalty', '1.0')
)

foreach ($name in $config.Profiles.Keys) {
    $profileArgs = @($config.Profiles[$name])

    if ($profileArgs -contains '--no-mmproj') {
        throw "Profile '$name' disables multimodal support."
    }
    if ($profileArgs -contains '--fit-target') {
        throw "Profile '$name' must not use --fit-target."
    }
    if ($profileArgs -contains '--cache-reuse') {
        throw "Profile '$name' must not use --cache-reuse."
    }

    foreach ($pair in $commonPairs) {
        Assert-FlagValue $profileArgs $pair[0] $pair[1] $name
    }

    foreach ($requiredFlag in @('--no-mmproj-offload', '--reasoning-preserve')) {
        if ($profileArgs -notcontains $requiredFlag) {
            throw "Profile '$name' must contain $requiredFlag."
        }
    }
}

Assert-FlagValue @($config.Profiles['Stable 160k']) '-c' '160000' 'Stable 160k'
Assert-FlagValue @($config.Profiles['Stable 160k']) '--fit-ctx' '160000' 'Stable 160k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '-c' '131072' 'MTP 128k'
Assert-FlagValue @($config.Profiles['MTP 128k']) '--fit-ctx' '131072' 'MTP 128k'

$mtp = @($config.Profiles['MTP 128k'])
Assert-FlagValue $mtp '--spec-type' 'draft-mtp' 'MTP 128k'
Assert-FlagValue $mtp '--spec-draft-n-max' '2' 'MTP 128k'
Assert-FlagValue $mtp '--spec-draft-type-k' 'q4_0' 'MTP 128k'
Assert-FlagValue $mtp '--spec-draft-type-v' 'q4_0' 'MTP 128k'

$bootstrap = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-bootstrap.ps1') -Raw
foreach ($needle in @(
    'QwenServerJob',
    'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE',
    'AssignProcessToJobObject',
    'Start-QwenDiagnosticsEncoded',
    'EncodedCommand',
    'QwenForegroundWindow'
)) {
    if ($bootstrap -notmatch [regex]::Escape($needle)) {
        throw "Bootstrap missing reliability primitive: $needle"
    }
}

$tray = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-app.ps1') -Raw
if ($tray -match 'ContextMenuStrip|ToolStripMenuItem') {
    throw 'Tray must use the custom popup.'
}
foreach ($needle in @(
    'Get-ProcessTreeIds',
    'Invoke-TaskKillSafe',
    '--metrics',
    'QwenPopupForm'
)) {
    if ($tray -notmatch [regex]::Escape($needle)) {
        throw "Tray missing expected behavior: $needle"
    }
}

$iconScript = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-icon.ps1') -Raw
if ($iconScript -match 'Procesps') {
    throw 'tray-icon contains the invalid Procesps typo.'
}
foreach ($needle in @(
    '$script:QwenRuntimeOverridesInstalled = $false',
    '$script:QwenLastSummaryKey = $null',
    'latest-runtime-summary.txt'
)) {
    if ($iconScript -notmatch [regex]::Escape($needle)) {
        throw "tray-icon missing expected runtime behavior: $needle"
    }
}

$diagPath = Join-Path $root 'scripts\runtime-diagnostics.ps1'
$diag = Get-Content -LiteralPath $diagPath -Raw
foreach ($needle in @(
    '/slots',
    '/metrics',
    'GPUProcessMemory',
    'Requested context',
    'Auto-fit minimum',
    'not captured in current log',
    'GPU layers',
    'mmproj backend',
   'SelfTest'
)) {
    if ($diag -notmatch [regex]::Escape($needle)) {
        throw "Diagnostics missing expected signal: $needle"
    }
}

foreach ($scriptText in @($bootstrap, $tray, $iconScript, $diag)) {
    if ($scriptText -match '[^\x00-\x7F]') {
        throw 'Runtime scripts must remain ASCII-only for Windows PowerShell 5.1 compatibility.'
    }
}

. (Join-Path $root 'scripts\tray-theme.ps1')
$smoke = New-QwenPopupForm
$smoke.Controls.Add((New-QwenPopupButton 'Smoke test'))
$smoke.Dispose()

& $diagPath -Root $root -SelfTest

$iconPath = Join-Path $root 'assets\QwenLocalLauncher.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw 'Missing versioned ICO.'
}

$builder = Get-Content -LiteralPath (Join-Path $root 'scripts\build-launcher.ps1') -Raw
if ($builder -notmatch '/win32icon:') {
    throw 'Launcher must embed the versioned ICO.'
}

Write-Host 'Static checks passed.'
