#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$assets = Join-Path $root 'assets'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

if (-not $OutputPath) { $OutputPath = Join-Path $dist 'Qwen Local Launcher.exe' }
$source = Join-Path $root 'launcher\QwenLocalLauncher.cs'
$iconPath = Join-Path $assets 'QwenLocalLauncher.ico'

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
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw "Launcher icon not found: $iconPath" }

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
Write-Host "Icon: $iconPath" -ForegroundColor DarkGray
if (-not $NoShortcuts) { Write-Host 'Desktop and Start Menu shortcuts installed.' -ForegroundColor Green }
