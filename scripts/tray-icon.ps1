#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-QwenBrandIcon {
    param([Parameter(Mandatory)][string]$IconPath)

    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
        throw "Tray icon not found: $IconPath"
    }

    $stream = [IO.File]::OpenRead($IconPath)
    try {
        $temporary = New-Object System.Drawing.Icon($stream, 32, 32)
        try { return $temporary.Clone() } finally { $temporary.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Register-QwenTrayIcon {
    param([Parameter(Mandatory)][string]$IconPath)

    $script:QwenTrayIconPath = $IconPath
    $script:QwenBrandIcon = $null

    $handler = [System.EventHandler]{
        $notifyVar = Get-Variable -Name NotifyIcon -Scope Script -ErrorAction SilentlyContinue
        if (-not $notifyVar -or $notifyVar.Value -isnot [System.Windows.Forms.NotifyIcon]) { return }

        $notify = $notifyVar.Value
        if ($script:QwenBrandIcon -and [object]::ReferenceEquals($notify.Icon, $script:QwenBrandIcon)) { return }

        $script:QwenBrandIcon = New-QwenBrandIcon -IconPath $script:QwenTrayIconPath
        $notify.Icon = $script:QwenBrandIcon
    }

    [System.Windows.Forms.Application]::add_Idle($handler)
}
