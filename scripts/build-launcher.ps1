#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('QwenBuildNativeIcon' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class QwenBuildNativeIcon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@
}

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$assets = Join-Path $root 'assets'
New-Item -ItemType Directory -Force -Path $dist, $assets | Out-Null

if (-not $OutputPath) { $OutputPath = Join-Path $dist 'Qwen Local Launcher.exe' }
$source = Join-Path $root 'launcher\QwenLocalLauncher.cs'
$iconSource = Join-Path $assets 'QwenLocalLauncher.png'
$iconPath = Join-Path $assets 'QwenLocalLauncher.ico'

function Convert-PngToLauncherIcon {
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [Parameter(Mandatory)][string]$IconPath
    )

    if (-not (Test-Path -LiteralPath $PngPath -PathType Leaf)) {
        throw "Launcher icon source not found: $PngPath"
    }

    $sourceImage = [System.Drawing.Image]::FromFile($PngPath)
    try {
        if ($sourceImage.Width -lt 256 -or $sourceImage.Height -lt 256) {
            throw "Launcher icon source must be at least 256x256. Current size: $($sourceImage.Width)x$($sourceImage.Height)."
        }

        $bitmap = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($sourceImage, 0, 0, 256, 256)

            $handle = $bitmap.GetHicon()
            try {
                $temporary = [System.Drawing.Icon]::FromHandle($handle)
                $icon = $temporary.Clone()
                try {
                    $stream = [IO.File]::Create($IconPath)
                    try { $icon.Save($stream) } finally { $stream.Dispose() }
                } finally { $icon.Dispose() }
            } finally {
                [QwenBuildNativeIcon]::DestroyIcon($handle) | Out-Null
            }
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    } finally {
        $sourceImage.Dispose()
    }
}

function Find-CSharpCompiler {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'C# compiler (csc.exe) was not found in the .NET Framework directories.'
}

function New-Shortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        $shortcut.WorkingDirectory = $root
        $shortcut.IconLocation = "$Target,0"
        $shortcut.Description = 'Qwen Local Launcher'
        $shortcut.Save()
    } finally {
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Launcher source not found: $source" }
Convert-PngToLauncherIcon -PngPath $iconSource -IconPath $iconPath

$csc = Find-CSharpCompiler
$args = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    "/win32icon:$iconPath",
    "/out:$OutputPath",
    $source
)
& $csc $args
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw 'Launcher executable was not created.' }

if (-not $NoShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) { New-Shortcut -Path (Join-Path $desktop 'Qwen Local Launcher.lnk') -Target $OutputPath }

    $programs = [Environment]::GetFolderPath('Programs')
    if ($programs) { New-Shortcut -Path (Join-Path $programs 'Qwen Local Launcher.lnk') -Target $OutputPath }
}

Write-Host "Launcher built: $OutputPath" -ForegroundColor Green
Write-Host "Icon source: $iconSource" -ForegroundColor DarkGray
if (-not $NoShortcuts) { Write-Host 'Desktop and Start Menu shortcuts installed.' -ForegroundColor Green }
