#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-QwenBrandIcon {
    param([Parameter(Mandatory)][string]$PngPath)

    $icoPath = [IO.Path]::ChangeExtension($PngPath, '.ico')
    if (Test-Path -LiteralPath $icoPath -PathType Leaf) {
        $stream = [IO.File]::OpenRead($icoPath)
        try {
            $temporary = New-Object System.Drawing.Icon($stream, 32, 32)
            try { return $temporary.Clone() } finally { $temporary.Dispose() }
        } finally { $stream.Dispose() }
    }

    throw "Generated tray icon not found: $icoPath. Run setup.cmd or scripts\build-launcher.ps1 first."
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

        $script:QwenBrandIcon = New-QwenBrandIcon -PngPath $script:QwenTrayIconPath
        $notify.Icon = $script:QwenBrandIcon
    }

    [System.Windows.Forms.Application]::add_Idle($handler)
}
