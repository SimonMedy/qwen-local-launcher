#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('QwenNativeIcon' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class QwenNativeIcon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@
}

function New-QwenBrandIcon {
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [int]$Size = 32
    )

    if (-not (Test-Path -LiteralPath $PngPath -PathType Leaf)) {
        throw "Tray icon source not found: $PngPath"
    }

    $source = [System.Drawing.Image]::FromFile($PngPath)
    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($source, 0, 0, $Size, $Size)

        $handle = $bitmap.GetHicon()
        try {
            $temporary = [System.Drawing.Icon]::FromHandle($handle)
            return $temporary.Clone()
        } finally {
            [QwenNativeIcon]::DestroyIcon($handle) | Out-Null
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
        $source.Dispose()
    }
}

function Register-QwenTrayIcon {
    param([Parameter(Mandatory)][string]$PngPath)

    $script:QwenTrayIconPath = $PngPath
    $script:QwenBrandIcon = $null

    $handler = [System.EventHandler]{
        $notifyVar = Get-Variable -Name NotifyIcon -Scope Script -ErrorAction SilentlyContinue
        if (-not $notifyVar -or $notifyVar.Value -isnot [System.Windows.Forms.NotifyIcon]) { return }

        $notify = $notifyVar.Value
        if ($script:QwenBrandIcon -and [object]::ReferenceEquals($notify.Icon, $script:QwenBrandIcon)) { return }

        $script:QwenBrandIcon = New-QwenBrandIcon -PngPath $script:QwenTrayIconPath -Size 32
        $notify.Icon = $script:QwenBrandIcon
    }

    [System.Windows.Forms.Application]::add_Idle($handler)
}
