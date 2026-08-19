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
$script:State = 'Stopped'
$script:Process = $null
$script:CurrentProfile = $null
$script:LastError = $null
$script:Stopping = $false
$script:StartupDeadline = $null
$script:LastExitCode = $null
$script:StdOutLog = $null
$script:StdErrLog = $null
$script:ProfileMenuItems = @{}

New-Item -ItemType Directory -Force -Path $script:LogDir, $script:RuntimeDir | Out-Null

$mutex = New-Object System.Threading.Mutex($true, 'Local\QwenLocalLauncher.Tray', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('Qwen Local Launcher is already running.', 'Qwen Local Launcher') | Out-Null
    exit 0
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

$script:Config = Import-LauncherConfig
$script:CurrentProfile = [string]$script:Config.DefaultProfile
if (-not $script:Config.Profiles.Contains($script:CurrentProfile)) {
    $script:CurrentProfile = [string]($script:Config.Profiles.Keys | Select-Object -First 1)
}

function Resolve-LlamaServer {
    if ($script:Config.LlamaServerPath) {
        $candidate = [Environment]::ExpandEnvironmentVariables([string]$script:Config.LlamaServerPath)
        if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $script:Root $candidate }
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "Configured llama-server.exe not found: $candidate"
    }

    if ($env:QWEN_LLAMA_SERVER -and (Test-Path -LiteralPath $env:QWEN_LLAMA_SERVER)) {
        return (Resolve-Path -LiteralPath $env:QWEN_LLAMA_SERVER).Path
    }

    $bundled = Join-Path $script:Root 'llama.cpp\llama-server.exe'
    if (Test-Path -LiteralPath $bundled) { return (Resolve-Path -LiteralPath $bundled).Path }

    $command = Get-Command 'llama-server.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    throw 'llama-server.exe was not found. Set LlamaServerPath in config/local.psd1, set QWEN_LLAMA_SERVER, place llama.cpp under the repo, or add llama-server.exe to PATH.'
}

function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ServerArguments {
    $profileArgs = @($script:Config.Profiles[$script:CurrentProfile])
    $args = @($profileArgs)
    $args += @('--host', [string]$script:Config.Host, '--port', [string]$script:Config.Port)
    return $args
}

function New-StatusIcon {
    param([ValidateSet('Stopped','Starting','Running','Error')][string]$Status)
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        switch ($Status) {
            'Running'  { $fill = [System.Drawing.Color]::FromArgb(35, 170, 95) }
            'Starting' { $fill = [System.Drawing.Color]::FromArgb(235, 166, 35) }
            'Error'    { $fill = [System.Drawing.Color]::FromArgb(220, 65, 65) }
            default    { $fill = [System.Drawing.Color]::FromArgb(120, 125, 135) }
        }
        $brush = New-Object System.Drawing.SolidBrush $fill
        $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $font = New-Object System.Drawing.Font 'Segoe UI', 15, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        try {
            $g.FillEllipse($brush, 1, 1, 30, 30)
            $format = New-Object System.Drawing.StringFormat
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString('Q', $font, $textBrush, [System.Drawing.RectangleF]::new(0,0,32,31), $format)
            $format.Dispose()
            return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        } finally {
            $brush.Dispose(); $textBrush.Dispose(); $font.Dispose()
        }
    } finally { $g.Dispose(); $bitmap.Dispose() }
}

function Set-LauncherState {
    param(
        [ValidateSet('Stopped','Starting','Running','Error')][string]$State,
        [string]$Detail
    )
    $script:State = $State
    $script:LastError = if ($State -eq 'Error') { $Detail } else { $null }

    if ($script:NotifyIcon.Icon) { $script:NotifyIcon.Icon.Dispose() }
    $script:NotifyIcon.Icon = New-StatusIcon $State
    $tooltip = "Qwen Local - $State"
    if ($script:CurrentProfile) { $tooltip += " - $($script:CurrentProfile)" }
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0,63) }
    $script:NotifyIcon.Text = $tooltip
    $script:StatusItem.Text = if ($Detail) { "$State - $Detail" } else { "$State - $($script:CurrentProfile)" }

    $script:StartItem.Enabled = $State -in @('Stopped','Error')
    $script:StopItem.Enabled = $State -in @('Starting','Running')
    $script:RestartItem.Enabled = $State -in @('Starting','Running','Error')
    foreach ($name in $script:ProfileMenuItems.Keys) {
        $item = $script:ProfileMenuItems[$name]
        $item.Checked = $name -eq $script:CurrentProfile
        $item.Enabled = $State -in @('Stopped','Error')
    }
}

function Test-ServerHealth {
    try {
        $uri = "http://$($script:Config.Host):$($script:Config.Port)$($script:Config.HealthPath)"
        Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 1 | Out-Null
        return $true
    } catch { return $false }
}

function Start-QwenServer {
    if ($script:Process -and -not $script:Process.HasExited) { return }
    try {
        $exe = Resolve-LlamaServer
        $args = Get-ServerArguments
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeProfile = $script:CurrentProfile -replace '[^A-Za-z0-9._-]', '_'
        $script:StdOutLog = Join-Path $script:LogDir "$stamp-$safeProfile.stdout.log"
        $script:StdErrLog = Join-Path $script:LogDir "$stamp-$safeProfile.stderr.log"

        $quoted = @($args | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' '
        "[$(Get-Date -Format o)] $exe $quoted" | Set-Content -LiteralPath (Join-Path $script:LogDir 'last-command.txt') -Encoding UTF8

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $quoted
        $psi.WorkingDirectory = Split-Path -Parent $exe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $script:Process = $process

        $outWriter = [IO.StreamWriter]::new($script:StdOutLog, $true, [Text.UTF8Encoding]::new($false))
        $errWriter = [IO.StreamWriter]::new($script:StdErrLog, $true, [Text.UTF8Encoding]::new($false))
        $process.add_OutputDataReceived({ param($sender,$e) if ($null -ne $e.Data) { $outWriter.WriteLine($e.Data); $outWriter.Flush() } })
        $process.add_ErrorDataReceived({ param($sender,$e) if ($null -ne $e.Data) { $errWriter.WriteLine($e.Data); $errWriter.Flush() } })
        $process.BeginOutputReadLine(); $process.BeginErrorReadLine()

        Set-Content -LiteralPath (Join-Path $script:RuntimeDir 'llama-server.pid') -Value $process.Id -Encoding ASCII
        $script:StartupDeadline = (Get-Date).AddSeconds([int]$script:Config.StartupTimeoutSeconds)
        $script:LastExitCode = $null
        Set-LauncherState 'Starting' 'loading model'
    } catch {
        Set-LauncherState 'Error' $_.Exception.Message
        $script:NotifyIcon.ShowBalloonTip(5000, 'Qwen Local Launcher', $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-QwenServer {
    param([switch]$ForRestart)
    $script:Stopping = $true
    try {
        if ($script:Process -and -not $script:Process.HasExited) {
            $pidToStop = $script:Process.Id
            & "$env:SystemRoot\System32\taskkill.exe" /PID $pidToStop /T 2>$null | Out-Null
            try { $script:Process.WaitForExit([int]$script:Config.StopTimeoutSeconds * 1000) | Out-Null } catch {}
            if (-not $script:Process.HasExited) {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $pidToStop /T /F 2>$null | Out-Null
                try { $script:Process.WaitForExit(3000) | Out-Null } catch {}
            }
        }
    } finally {
        Remove-Item -LiteralPath (Join-Path $script:RuntimeDir 'llama-server.pid') -Force -ErrorAction SilentlyContinue
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

function Test-StartupEnabled { Test-Path -LiteralPath (Get-StartupShortcutPath) }

function Set-StartupEnabled {
    param([bool]$Enabled)
    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = Join-Path $script:Root 'scripts\launch-hidden.vbs'
        $shortcut.WorkingDirectory = $script:Root
        $shortcut.Description = 'Qwen Local Launcher'
        $shortcut.Save()
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
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
    [System.Windows.Forms.MessageBox]::Show(
        "Qwen Local Launcher`r`nWindows tray controller for llama.cpp`r`n`r`nProfile: $($script:CurrentProfile)",
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
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.add_DoubleClick({ if ($script:State -eq 'Running') { Open-WebUi } else { Start-QwenServer } })

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = [int]$script:Config.PollIntervalMilliseconds
$script:Timer.add_Tick({
    if ($script:Process) {
        $script:Process.Refresh()
        if ($script:Process.HasExited) {
            $exitCode = $script:Process.ExitCode
            $script:LastExitCode = $exitCode
            Remove-Item -LiteralPath (Join-Path $script:RuntimeDir 'llama-server.pid') -Force -ErrorAction SilentlyContinue
            $script:Process = $null
            if (-not $script:Stopping) {
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
})

Set-LauncherState 'Stopped' $null
$script:Timer.Start()
if ($StartImmediately) { Start-QwenServer }

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($script:NotifyIcon -and $script:NotifyIcon.Visible) { Exit-Launcher }
}
