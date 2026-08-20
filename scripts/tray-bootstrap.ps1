#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

if (-not ('QwenForegroundWindow' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class QwenForegroundWindow
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    public static IntPtr Current()
    {
        return GetForegroundWindow();
    }
}
"@
}

function Register-QwenPopupBehaviorGuards {
    $script:QwenInteractionGuardsInstalled = $false

    $installHandler = [System.EventHandler]{
        if ($script:QwenInteractionGuardsInstalled) { return }

        $popupVar = Get-Variable -Name Popup -Scope Script -ErrorAction SilentlyContinue
        $stopVar = Get-Variable -Name StopButton -Scope Script -ErrorAction SilentlyContinue
        $restartVar = Get-Variable -Name RestartButton -Scope Script -ErrorAction SilentlyContinue
        $timerVar = Get-Variable -Name Timer -Scope Script -ErrorAction SilentlyContinue
        if (-not $popupVar -or -not $stopVar -or -not $restartVar -or -not $timerVar) { return }

        $script:QwenInteractionGuardsInstalled = $true
        $script:QwenExpectedServerStop = $false
        $script:QwenExpectedServerRestart = $false

        $stopVar.Value.add_MouseDown({
            $script:QwenExpectedServerStop = $true
            try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
        })
        $stopVar.Value.add_Click({
            try {
                if ($script:QwenExpectedServerStop -and (-not $script:Process -or $script:Process.HasExited)) {
                    Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
                    $script:Process = $null
                    Set-LauncherState 'Stopped' $null
                }
            } catch {
                try { Write-TrayRuntimeError $_ } catch {}
            } finally {
                $script:QwenExpectedServerStop = $false
                try { if ($script:Timer) { $script:Timer.Start() } } catch {}
            }
        })

        $restartVar.Value.add_MouseDown({
            $script:QwenExpectedServerRestart = $true
            try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
        })
        $restartVar.Value.add_Click({
            $script:QwenExpectedServerRestart = $false
            try { if ($script:Timer) { $script:Timer.Start() } } catch {}
        })

        $script:QwenPopupGuardTimer = New-Object System.Windows.Forms.Timer
        $script:QwenPopupGuardTimer.Interval = 100
        $script:QwenPopupGuardTimer.add_Tick({
            try {
                if ($script:Popup -and $script:Popup.Visible) {
                    $foreground = [QwenForegroundWindow]::Current()
                    if ($foreground -ne $script:Popup.Handle -and -not $script:Popup.ContainsFocus) {
                        $script:Popup.Hide()
                        $script:ProfileExpanded = $false
                        try { Update-PopupLayout } catch {}
                    }
                }
            } catch {
                try { Write-TrayRuntimeError $_ } catch {}
            }
        })
        $script:QwenPopupGuardTimer.Start()
    }

    [System.Windows.Forms.Application]::add_Idle($installHandler)
}

$createdNew = $false
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

try {
    . (Join-Path $PSScriptRoot 'tray-theme.ps1')
    Register-QwenTrayTheme

    . (Join-Path $PSScriptRoot 'tray-icon.ps1')
    Register-QwenTrayIcon -IconPath (Join-Path $root 'assets\QwenLocalLauncher.ico')

    Register-QwenPopupBehaviorGuards
    . (Join-Path $PSScriptRoot 'tray-app.ps1')
} catch {
    $message = $_ | Out-String
    $logPath = Join-Path $logDir 'tray-startup-error.log'
    $message | Set-Content -LiteralPath $logPath -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show(
        "Qwen Local Launcher could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails were written to:`r`n$logPath",
        'Qwen Local Launcher - Startup Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
