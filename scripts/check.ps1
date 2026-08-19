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
foreach ($name in @('Stable 160k','MTP 160k','Stable 180k')) {
    if (-not $config.Profiles.Contains($name)) { throw "Missing required profile: $name" }
}
foreach ($name in $config.Profiles.Keys) {
    $args = @($config.Profiles[$name])
    if ($args -contains '--no-mmproj') { throw "Profile '$name' disables multimodal support." }
    if ($args -notcontains '-hf') { throw "Profile '$name' must specify a Hugging Face model." }
    if ($args -notcontains '-c') { throw "Profile '$name' must specify context size." }
}

$iconSource = Join-Path $root 'assets\QwenLocalLauncher.png'
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) { throw 'Missing assets/QwenLocalLauncher.png.' }

$bootstrap = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-bootstrap.ps1') -Raw
if ($bootstrap -notmatch 'tray-icon\.ps1') { throw 'Tray bootstrap must load tray-icon.ps1.' }

$trayIcon = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-icon.ps1') -Raw
if ($trayIcon -notmatch 'ChangeExtension') { throw 'Tray icon must load the generated ICO.' }
if ($trayIcon -notmatch 'System.Drawing.Icon') { throw 'Tray icon must use the ICO directly.' }

$theme = Get-Content -LiteralPath (Join-Path $root 'scripts\tray-theme.ps1') -Raw
if ($theme -notmatch 'QwenMenuRenderer') { throw 'Tray theme must define QwenMenuRenderer.' }

$builder = Get-Content -LiteralPath (Join-Path $root 'scripts\build-launcher.ps1') -Raw
if ($builder -notmatch 'Convert-PngToMultiSizeIcon') { throw 'Launcher build must generate a multi-size ICO.' }
foreach ($size in @('16','32','48','64','128','256')) {
    if ($builder -notmatch "\b$size\b") { throw "Multi-size ICO is missing size $size." }
}
if ($builder -notmatch '/win32icon:') { throw 'Launcher build must embed the generated ICO.' }
if ($builder -notmatch 'Qwen Local Launcher\.lnk') { throw 'Build script must create Windows shortcuts.' }

$source = Get-Content -LiteralPath (Join-Path $root 'launcher\QwenLocalLauncher.cs') -Raw
if ($source -notmatch 'Directory\.GetParent') { throw 'Launcher in dist must resolve the project root via its parent directory.' }

$setup = Get-Content -LiteralPath (Join-Path $root 'setup.cmd') -Raw
if ($setup -notmatch 'dist\\Qwen Local Launcher\.exe') { throw 'Setup must launch the executable from dist.' }

Write-Host 'Static checks passed.'
