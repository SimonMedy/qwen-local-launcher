#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (-not $OutputPath) { $OutputPath = Join-Path $dist 'Qwen Local Launcher.exe' }
$source = Join-Path $root 'launcher\QwenLocalLauncher.cs'
$assets = Join-Path $root 'assets'
$iconPath = Join-Path $assets 'QwenLocalLauncher.ico'
New-Item -ItemType Directory -Force -Path $assets | Out-Null

function New-QwenLauncherIcon {
    param([Parameter(Mandatory)][string]$Path)
    $bitmap = New-Object System.Drawing.Bitmap 256, 256
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rect = New-Object System.Drawing.Rectangle(8, 8, 240, 240)
        $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,[System.Drawing.Color]::FromArgb(28,30,38),[System.Drawing.Color]::FromArgb(40,44,62),90.0)
        $ring = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(111,211,255),24)
        $tail = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(145,160,255),24)
        $dot = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(72,232,170))
        try {
            $g.FillEllipse($bg,8,8,240,240); $g.DrawEllipse($ring,58,52,140,140); $g.DrawLine($tail,164,165,209,210); $g.FillEllipse($dot,184,47,28,28)
        } finally { $bg.Dispose(); $ring.Dispose(); $tail.Dispose(); $dot.Dispose() }
        $hIcon = $bitmap.GetHicon(); $icon = [System.Drawing.Icon]::FromHandle($hIcon)
        try { $stream = [IO.File]::Create($Path); try { $icon.Save($stream) } finally { $stream.Dispose() } } finally { $icon.Dispose() }
    } finally { $g.Dispose(); $bitmap.Dispose() }
}

function Find-CSharpCompiler {
    $candidates = @((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    throw 'C# compiler (csc.exe) was not found in the .NET Framework directories.'
}

function New-Shortcut {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Target)
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        $shortcut.WorkingDirectory = $root
        $shortcut.IconLocation = "$Target,0"
        $shortcut.Description = 'Qwen Local Launcher'
        $shortcut.Save()
    } finally { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
}

if (-not (Test-Path -LiteralPath $source)) { throw "Launcher source not found: $source" }
New-QwenLauncherIcon -Path $iconPath
$csc = Find-CSharpCompiler
$args = @('/nologo','/target:winexe','/optimize+','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll',"/win32icon:$iconPath","/out:$OutputPath",$source)
& $csc $args
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $OutputPath)) { throw 'Launcher executable was not created.' }

if (-not $NoShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) { New-Shortcut -Path (Join-Path $desktop 'Qwen Local Launcher.lnk') -Target $OutputPath }
    $programs = [Environment]::GetFolderPath('Programs')
    if ($programs) { New-Shortcut -Path (Join-Path $programs 'Qwen Local Launcher.lnk') -Target $OutputPath }
}

Write-Host "Launcher built: $OutputPath" -ForegroundColor Green
if (-not $NoShortcuts) { Write-Host 'Desktop and Start Menu shortcuts installed.' -ForegroundColor Green }
