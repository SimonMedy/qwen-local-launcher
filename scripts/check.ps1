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
if ((@($config.ProfileOrder) -join '|') -ne 'Stable 160k|MTP Tuned') { throw 'ProfileOrder must be Stable 160k then MTP Tuned.' }

function Assert-ExactProfile {
    param(
        [Parameter(Mandatory)][object[]]$Actual,
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Actual.Count -ne $Expected.Count) {
        throw "Profile '$Name' argument count mismatch: actual=$($Actual.Count), expected=$($Expected.Count)."
    }
    for ($i = 0; $i -lt $Expected.Count;$i++) {
        if ([string]$Actual[$i] -ne [string]$Expected[$i]) {
            throw "Profile '$Name' differs at index ${i}: actual='$($Actual[$i])', expected='$($Expected[$i])'."
        }
    }
}

$stableExpected = @(
    '-hf','unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
    '-c','50000',
    '-ngl','auto',
    '--cache-type-k','q8_0',
    '--cache-type-v','q4_0',
    '--flash-attn','on',
    '--image-min-tokens','1024',
    '--no-mmproj-offload',
    '-np','1',
    '--cache-ram','2048',
    '-b','1024',
   '-ub','512',
    '-t','8',
   '-tb','16',
   '--reasoning-preserve',
   '--temp','1.0',
    '--top-p','0.95',
    '--top-k','20',
    '--min-p','0.0',
    '--presence-penalty','0.0',
   '--repeat-penalty','1.0'
)

$mtpExpected = @(
    '-hf','unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
    '-c','50000',
    '-ngl','auto',
   '--fit-target','512',
    '--cache-type-k','q5_1',
   '--cache-type-v','q5_1',
    '--flash-attn','on',
    '--image-min-tokens','1024',
    '--no-mmproj-offload',
    '-np','1',
    '-b','1024',
    '-ub','128',
   '--cache-ram','2048',
    '--ctx-checkpoints','64',
    '-t','8',
   '-tb','16',
   '--spec-type','draft-mtp,ngram-mod',
    '--spec-draft-n-max','2',
    '--spec-draft-p-min','0.82',
    '--spec-draft-type-k','q4_0',
    '--spec-draft-type-v','q4_0',
   '--spec-ngram-mod-n-match','24',
   '--spec-ngram-mod-n-min','48',
    '--spec-ngram-mod-n-max','64',
   '--reasoning-preserve',
   '--temp','1.0',
    '--top-p','0.95',
    '--top-k','20',
    '--min-p','0.0',
    '--presence-penalty','0.0',
   '--repeat-penalty','1.0'
)

Assert-ExactProfile -Actual @($config.Profiles['Stable 160k']) -Expected $stableExpected -Name 'Stable 160k'
Assert-ExactProfile -Actual @($config.Profiles['MTP Tuned']) -Expected $mtpExpected -Name 'MTP Tuned'

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
