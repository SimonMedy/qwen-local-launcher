#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$StartImmediately
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'config\profiles.psd1' }
$script:LogDir = Join-Path $script:Root 'logs'
$script:RuntimeDir = Join-Path $script:Root 'runtime'
$script:PidPath = Join-Path $script:RuntimeDir 'llama-server.pid'
$script:State = 'Stopped'
$script:Process = $null
$script:CurrentProfile = $null
$script:Stopping = $false
$script:StartupDeadline = $null
$script:ProfileMenuItems = @{}
$script:ChangingLlama = $false

New-Item -ItemType Directory -Force -Path $script:LogDir, $script:RuntimeDir | Out-Null

$mutex = New-Object System.Threading.Mutex($true, 'Local\QwenLocalLauncher.Tray', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('Qwen Local Launcher is already running.', 'Qwen Local Launcher') | Out-Null
    exit 0
}

function Write-TrayRuntimeError {
    param([Parameter(Mandatory)][object]$ErrorRecord)
    try {
        $entry = "[$(Get-Date -Format o)] $($ErrorRecord | Out-String)"
        Add-Content -LiteralPath (Join-Path $script:LogDir 'tray-runtime-error.log') -Value $entry -Encoding UTF8
    } catch {}
}

function Import-LauncherConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $localPath = Join-Path (Split-Path -Parent $ConfigPath) 'local.psd1'
    if (Test-Path -LiteralPath $localPath) {
        $local = Import-PowerShellDataFile -LiteralPath $localPath
        foreach ($key in $local.Keys) { $config[$key] = $local[$key] }
    }
    if (-not $config.Profiles -or $config.Profiles.Count -eq 0) { throw 'No profiles are configured.' }
    return $config
}

function Reload-LauncherConfig {
    $oldProfile = $script:CurrentProfile
    $script:Config = Import-LauncherConfig
    if ($oldProfile -and $script:Config.Profiles.Contains($oldProfile)) {
        $script:CurrentProfile = $oldProfile
    } elseif ($script:Config.Profiles.Contains([string]$script:Config.DefaultProfile)) {
        $script:CurrentProfile = [string]$script:Config.DefaultProfile
    } else {
        $script:CurrentProfile = [string]($script:Config.Profiles.Keys | Select-Object -First 1)
    }
}

Reload-LauncherConfig

function Resolve-LlamaServer {
    if ($script:Config.LlamaServerPath) {
        $candidate = [Environment]::ExpandEnvironmentVariables([string]$script:Config.LlamaServerPath)
        if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $script:Root $candidate }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "Configured llama-server.exe not found: $candidate"
    }
    throw 'No llama-server.exe is configured. Use Change llama.cpp... from the tray menu.'
}

function Get-LlamaLabel {
    try {
        $exe = Resolve-LlamaServer
        $parent = Split-Path -Leaf (Split-Path -Parent $exe)
        if ([string]::IsNullOrWhiteSpace($parent)) { return 'llama.cpp configured' }
        return "llama.cpp: $parent"
    } catch {
        return 'llama.cpp: not configured'
    }
}

function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ServerArguments {
    $serverArgs = @($script:Config.Profiles[$script:CurrentProfile])
    $serverArgs += @('--host', [string]$script:Config.Host, '--port', [string]$script:Config.Port)
    return $serverArgs
}

function Set-LauncherState {
    param(
        [ValidateSet('Stopped','Starting','Running','Error')][string]$State,
        [string]$Detail
    )

    $script:State = $State
    $tooltip = "Qwen Local - $State - $($script:CurrentProfile)"
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
    $script:NotifyIcon.Text = $tooltip
    $script:StatusItem.Text = if ($Detail) { "$State - $Detail" } else { "$State - $($script:CurrentProfile)" }
    $script:LlamaInfoItem.Text = Get-LlamaLabel

    $script:StartItem.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Stopped','Error'))
    $script:StopItem.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Starting','Running'))
    $script:RestartItem.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Starting','Running','Error'))
    $script:ChangeLlamaItem.Enabled = -not $script:ChangingLlama

    foreach ($name in $script:ProfileMenuItems.Keys) {
        $item = $script:ProfileMenuItems[$name]
        $item.Checked = $name -eq $script:CurrentProfile
        $item.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Stopped','Error'))
    }
}

function Test-ServerHealth {
    try {
        $uri = "http://$($script:Config.Host):$($script:Config.Port)$($script:Config.HealthPath)"
        Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 1 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Connect-ExistingQwenServer {
    if (-not (Test-Path -LiteralPath $script:PidPath -PathType Leaf)) { return $false }

    try {
        $pidText = (Get-Content -LiteralPath $script:PidPath -Raw).Trim()
        $serverPid = 0
        if (-not [int]::TryParse($pidText, [ref]$serverPid) -or $serverPid -le 0) { throw 'Invalid PID file.' }

        $existing = Get-Process -Id $serverPid -ErrorAction Stop
        if ($existing.ProcessName -ne 'llama-server') { throw "PID $serverPid is not llama-server.exe." }

        $script:Process = $existing
        if (Test-ServerHealth) {
            Set-LauncherState 'Running' 'reconnected to existing server'
        } else {
            $script:StartupDeadline = (Get-Date).AddSeconds(30)
            Set-LauncherState 'Starting' 'reconnected; health check pending'
        }
        return $true
    } catch {
        Write-TrayRuntimeError $_
        Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
        $script:Process = $null
        return $false
    }
}

function Start-QwenServer {
    if ($script:Process) {
        try {
            $script:Process.Refresh()
            if (-not $script:Process.HasExited) { return }
        } catch {
            $script:Process = $null
        }
    }

    try {
        $exe = Resolve-LlamaServer
        $serverArgs = Get-ServerArguments
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeProfile = $script:CurrentProfile -replace '[^A-Za-z0-9._-]', '_'
        $stdout = Join-Path $script:LogDir "$stamp-$safeProfile.stdout.log"
        $stderr = Join-Path $script:LogDir "$stamp-$safeProfile.stderr.log"
        $quoted = @($serverArgs | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' '

        "[$(Get-Date -Format o)] $exe $quoted" | Set-Content -LiteralPath (Join-Path $script:LogDir 'last-command.txt') -Encoding UTF8

        $process = Start-Process -FilePath $exe `
            -ArgumentList $quoted `
            -WorkingDirectory (Split-Path -Parent $exe) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -PassThru

        if (-not $process) { throw 'Start-Process did not return a process.' }
        $script:Process = $process
        Set-Content -LiteralPath $script:PidPath -Value $process.Id -Encoding ASCII
        $script:StartupDeadline = (Get-Date).AddSeconds([int]$script:Config.StartupTimeoutSeconds)
        Set-LauncherState 'Starting' 'loading model'
    } catch {
        Write-TrayRuntimeError $_
        $script:Process = $null
        Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
        Set-LauncherState 'Error' $_.Exception.Message
        $script:NotifyIcon.ShowBalloonTip(5000, 'Qwen Local Launcher', $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-QwenServer {
    param([switch]$ForRestart)

    $script:Stopping = $true
    try {
        if (-not $script:Process) { [void](Connect-ExistingQwenServer) }
        if ($script:Process) {
            try {
                $script:Process.Refresh()
                if (-not $script:Process.HasExited) {
                    $pidToStop = $script:Process.Id
                    & "$env:SystemRoot\System32\taskkill.exe" /PID $pidToStop /T 2>$null | Out-Null
                    try { $script:Process.WaitForExit([int]$script:Config.StopTimeoutSeconds * 1000) | Out-Null } catch {}
                    $script:Process.Refresh()
                    if (-not $script:Process.HasExited) {
                        & "$env:SystemRoot\System32\taskkill.exe" /PID $pidToStop /T /F 2>$null | Out-Null
                        try { $script:Process.WaitForExit(3000) | Out-Null } catch {}
                    }
                }
            } catch {
                Write-TrayRuntimeError $_
            }
        }
    } finally {
        Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
        $script:Process = $null
        $script:StartupDeadline = $null
        $script:Stopping = $false
        if (-not $ForRestart) { Set-LauncherState 'Stopped' $null }
    }
}

function Restart-QwenServer {
    Stop-QwenServer -ForRestart
    Start-QwenServer
}

function Change-LlamaServer {
    if ($script:ChangingLlama) { return }

    $script:ChangingLlama = $true
    $wasRunning = $script:Process -and -not $script:Process.HasExited
    $oldConfig = $script:Config

    try {
        Set-LauncherState $script:State 'changing llama.cpp'
        if ($wasRunning) { Stop-QwenServer -ForRestart }
        $setupScript = Join-Path $script:Root 'scripts\configure-llama.ps1'
        $setupArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setupScript)
        $setup = Start-Process -FilePath 'powershell.exe' -ArgumentList $setupArgs -Wait -PassThru

        if ($setup.ExitCode -eq 0) {
            Reload-LauncherConfig
            $selected = Resolve-LlamaServer
            Set-LauncherState 'Stopped' $null
            $script:NotifyIcon.ShowBalloonTip(2500, 'llama.cpp changed', "Now using $selected", [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $script:Config = $oldConfig
            Set-LauncherState 'Stopped' 'change cancelled'
        }
    } catch {
        Write-TrayRuntimeError $_
        $script:Config = $oldConfig
        Set-LauncherState 'Error' $_.Exception.Message
        $script:NotifyIcon.ShowBalloonTip(5000, 'Could not change llama.cpp', $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    } finally {
        $script:ChangingLlama = $false
        Set-LauncherState $script:State $null
        if ($wasRunning) { Start-QwenServer }
    }
}

function Open-WebUi {
    Start-Process "http://$($script:Config.Host):$($script:Config.Port)/"
}

function Open-Logs {
    Start-Process 'explorer.exe' -ArgumentList $script:LogDir
}

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return Join-Path $startup 'Qwen Local Launcher.lnk'
}

function Test-StartupEnabled {
    return Test-Path -LiteralPath (Get-StartupShortcutPath)
}

function Set-StartupEnabled {
    param([bool]$Enabled)
    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        try {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = Join-Path $script:Root 'scripts\launch-hidden.vbs'
            $shortcut.WorkingDirectory = $script:Root
            $shortcut.Description = 'Qwen Local Launcher'
            $shortcut.Save()
        } finally {
            [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    } else {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    }
    $script:StartupItem.Checked = Test-StartupEnabled
}

function Exit-Launcher {
    $script:Timer.Stop()
    Stop-QwenServer
    $script:NotifyIcon.Visible = $false
    if ($script:NotifyIcon.Icon) { $script:NotifyIcon.Icon.Dispose() }
    $script:NotifyIcon.Dispose()
    $script:Menu.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Menu.ShowImageMargin = $false
$script:Menu.Font = New-Object System.Drawing.Font 'Segoe UI', 10

$script:StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:StatusItem.Enabled = $false
$script:StatusItem.Font = New-Object System.Drawing.Font 'Segoe UI Semibold', 10
[void]$script:Menu.Items.Add($script:StatusItem)

$script:LlamaInfoItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:LlamaInfoItem.Enabled = $false
[void]$script:Menu.Items.Add($script:LlamaInfoItem)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:StartItem = $script:Menu.Items.Add('Start')
$script:StopItem = $script:Menu.Items.Add('Stop')
$script:RestartItem = $script:Menu.Items.Add('Restart')
$script:StartItem.add_Click({ Start-QwenServer })
$script:StopItem.add_Click({ Stop-QwenServer })
$script:RestartItem.add_Click({ Restart-QwenServer })

$profileMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Profile'
foreach ($profileName in $script:Config.Profiles.Keys) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem ([string]$profileName)
    $item.CheckOnClick = $false
    $capturedName = [string]$profileName
    $item.add_Click({
        $script:CurrentProfile = $this.Text
        Set-LauncherState $script:State $null
    })
    $script:ProfileMenuItems[$capturedName] = $item
    [void]$profileMenu.DropDownItems.Add($item)
}
[void]$script:Menu.Items.Add($profileMenu)

$script:ChangeLlamaItem = $script:Menu.Items.Add('Change llama.cpp...')
$script:ChangeLlamaItem.add_Click({ Change-LlamaServer })

[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$webItem = $script:Menu.Items.Add('Open Web UI')
$logsItem = $script:Menu.Items.Add('Open logs')
$webItem.add_Click({ Open-WebUi })
$logsItem.add_Click({ Open-Logs })

[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$script:StartupItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$script:StartupItem.Checked = Test-StartupEnabled
$script:StartupItem.add_Click({ Set-StartupEnabled (-not (Test-StartupEnabled)) })
[void]$script:Menu.Items.Add($script:StartupItem)

$aboutItem = $script:Menu.Items.Add('About')
$aboutItem.add_Click({
    $llama = try { Resolve-LlamaServer } catch { 'Not configured' }
    [System.Windows.Forms.MessageBox]::Show(
        "Qwen Local Launcher`r`nWindows tray controller for llama.cpp`r`n`r`nProfile: $($script:CurrentProfile)`r`nllama.cpp: $llama",
        'About Qwen Local Launcher',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})

[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$quitItem = $script:Menu.Items.Add('Quit')
$quitItem.add_Click({ Exit-Launcher })

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.ContextMenuStrip = $script:Menu

try {
    $brandPathVar = Get-Variable -Name QwenTrayIconPath -Scope Script -ErrorAction SilentlyContinue
    if ($brandPathVar -and (Get-Command New-QwenBrandIcon -ErrorAction SilentlyContinue)) {
        $script:QwenBrandIcon = New-QwenBrandIcon -IconPath ([string]$brandPathVar.Value)
        $script:NotifyIcon.Icon = $script:QwenBrandIcon
    }
} catch {
    Write-TrayRuntimeError $_
}

$script:NotifyIcon.Visible = $true
$script:NotifyIcon.add_DoubleClick({ if ($script:State -eq 'Running') { Open-WebUi } else { Start-QwenServer } })

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = [int]$script:Config.PollIntervalMilliseconds
$script:Timer.add_Tick({
    try {
        if ($script:Process) {
            $script:Process.Refresh()
            if ($script:Process.HasExited) {
                $exitCode = $script:Process.ExitCode
                Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
                $script:Process = $null
                if (-not $script:Stopping -and -not $script:ChangingLlama) {
                    Set-LauncherState 'Error' "llama-server exited ($exitCode)"
                    $script:NotifyIcon.ShowBalloonTip(5000, 'Qwen server stopped', "llama-server exited with code $exitCode. Open logs for details.", [System.Windows.Forms.ToolTipIcon]::Error)
                }
                return
            }
        }

        if ($script:State -eq 'Starting') {
            if (Test-ServerHealth) {
                Set-LauncherState 'Running' $script:CurrentProfile
                $script:NotifyIcon.ShowBalloonTip(2500, 'Qwen is ready', "$($script:CurrentProfile) is serving on port $($script:Config.Port).", [System.Windows.Forms.ToolTipIcon]::Info)
            } elseif ($script:StartupDeadline -and (Get-Date) -gt $script:StartupDeadline) {
                Set-LauncherState 'Error' 'health check timed out'
            }
        } elseif ($script:State -eq 'Running' -and -not (Test-ServerHealth)) {
            Set-LauncherState 'Starting' 'health check pending'
            $script:StartupDeadline = (Get-Date).AddSeconds(15)
        }
    } catch {
        Write-TrayRuntimeError $_
        try { Set-LauncherState 'Error' 'tray monitor error; see logs' } catch {}
    }
})

Set-LauncherState 'Stopped' $null
[void](Connect-ExistingQwenServer)
$script:Timer.Start()
if ($StartImmediately -and -not $script:Process) { Start-QwenServer }

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($script:NotifyIcon -and $script:NotifyIcon.Visible) { Exit-Launcher }
}
