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
$script:ChangingLlama = $false
$script:ProfileExpanded = $false
$script:ProfileButtons = @{}

New-Item -ItemType Directory -Force -Path $script:LogDir, $script:RuntimeDir | Out-Null
$mutex = New-Object System.Threading.Mutex($true, 'Local\QwenLocalLauncher.Tray', [ref]$createdNew)
if (-not $createdNew) {
    [Windows.Forms.MessageBox]::Show('Qwen Local Launcher is already running.', 'Qwen Local Launcher') | Out-Null
    exit 0
}

function Write-TrayRuntimeError {
    param([Parameter(Mandatory)][object]$ErrorRecord)
    try { Add-Content -LiteralPath (Join-Path $script:LogDir 'tray-runtime-error.log') -Value "[$(Get-Date -Format o)] $($ErrorRecord | Out-String)" -Encoding UTF8 } catch {}
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
    if ($oldProfile -and $script:Config.Profiles.Contains($oldProfile)) { $script:CurrentProfile = $oldProfile }
    elseif ($script:Config.Profiles.Contains([string]$script:Config.DefaultProfile)) { $script:CurrentProfile = [string]$script:Config.DefaultProfile }
    else { $script:CurrentProfile = [string]($script:Config.Profiles.Keys | Select-Object -First 1) }
}
Reload-LauncherConfig

function Resolve-LlamaServer {
    if ($script:Config.LlamaServerPath) {
        $candidate = [Environment]::ExpandEnvironmentVariables([string]$script:Config.LlamaServerPath)
        if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $script:Root $candidate }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "Configured llama-server.exe not found: $candidate"
    }
    throw 'No llama-server.exe is configured. Use Change llama.cpp from the tray menu.'
}

function Get-LlamaLabel {
    try {
        $exe = Resolve-LlamaServer
        $parent = Split-Path -Leaf (Split-Path -Parent $exe)
        if ([string]::IsNullOrWhiteSpace($parent)) { return 'llama.cpp configured' }
        return "llama.cpp: $parent"
    } catch { return 'llama.cpp: not configured' }
}

function ConvertTo-CommandLineArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ServerArguments {
    $serverArgs = @($script:Config.Profiles[$script:CurrentProfile])
    if ($serverArgs -notcontains '--metrics') { $serverArgs += '--metrics' }
    $serverArgs += @('--host', [string]$script:Config.Host, '--port', [string]$script:Config.Port)
    return $serverArgs
}

function Update-PopupLayout {
    if (-not $script:Popup) { return }
    $y = 16
    $script:StatusLabel.SetBounds(18, $y, 324, 24); $y += 28
    $script:LlamaLabel.SetBounds(18, $y, 324, 22); $y += 30
    $script:Divider1.SetBounds(14, $y, 332, 1); $y += 9

    foreach ($button in @($script:StartButton,$script:StopButton,$script:RestartButton)) { $button.SetBounds(8,$y,344,40); $y += 40 }
    $y += 3
    $script:ProfileButton.SetBounds(8,$y,344,40); $y += 40
    foreach ($name in $script:ProfileOrder) {
        $button = $script:ProfileButtons[$name]
        if ($button) {
            $button.Visible = $script:ProfileExpanded
            if ($script:ProfileExpanded) { $button.SetBounds(18,$y,334,38); $y += 38 }
        }
    }
    $script:ChangeLlamaButton.SetBounds(8,$y,344,40); $y += 46
    $script:Divider2.SetBounds(14,$y,332,1); $y += 8
    foreach ($button in @($script:WebButton,$script:DiagnosticsButton,$script:LogsButton)) { $button.SetBounds(8,$y,344,40); $y += 40 }
    $y += 6
    $script:Divider3.SetBounds(14,$y,332,1); $y += 8
    $script:StartupButton.SetBounds(8,$y,344,40); $y += 40
    $script:AboutButton.SetBounds(8,$y,344,40); $y += 46
    $script:Divider4.SetBounds(14,$y,332,1); $y += 8
    $script:QuitButton.SetBounds(8,$y,344,40); $y += 48
    $script:Popup.Height = $y
}

function Set-LauncherState {
    param([ValidateSet('Stopped','Starting','Running','Error')][string]$State, [string]$Detail)
    $script:State = $State
    $tooltip = "Qwen Local - $State - $($script:CurrentProfile)"
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0,63) }
    if ($script:NotifyIcon) { $script:NotifyIcon.Text = $tooltip }
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = if ($Detail) { "$State - $Detail" } else { "$State - $($script:CurrentProfile)" }
        $script:StatusLabel.ForeColor = switch ($State) { 'Running' { [Drawing.Color]::FromArgb(87,242,135) } 'Starting' { [Drawing.Color]::FromArgb(250,166,26) } 'Error' { $script:QwenDanger } default { $script:QwenText } }
    }
    if ($script:LlamaLabel) { $script:LlamaLabel.Text = Get-LlamaLabel }
    if ($script:ProfileButton) { $script:ProfileButton.SecondaryText = $script:CurrentProfile }
    if ($script:StartButton) { $script:StartButton.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Stopped','Error')) }
    if ($script:StopButton) { $script:StopButton.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Starting','Running')) }
    if ($script:RestartButton) { $script:RestartButton.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Starting','Running','Error')) }
    if ($script:ChangeLlamaButton) { $script:ChangeLlamaButton.Enabled = -not $script:ChangingLlama }
    foreach ($name in $script:ProfileButtons.Keys) {
        $button = $script:ProfileButtons[$name]
        $button.IsChecked = $name -eq $script:CurrentProfile
        $button.Enabled = (-not $script:ChangingLlama) -and ($State -in @('Stopped','Error'))
    }
}

function Test-ServerHealth {
    try { Invoke-WebRequest -Uri "http://$($script:Config.Host):$($script:Config.Port)$($script:Config.HealthPath)" -UseBasicParsing -TimeoutSec 1 | Out-Null; return $true }
    catch { return $false }
}

function Connect-ExistingQwenServer {
    if (-not (Test-Path -LiteralPath $script:PidPath -PathType Leaf)) { return $false }
    try {
        $serverPid = [int](Get-Content -LiteralPath $script:PidPath -Raw).Trim()
        $existing = Get-Process -Id $serverPid -ErrorAction Stop
        if ($existing.ProcessName -ne 'llama-server') { throw "PID $serverPid is not llama-server.exe." }
        $script:Process = $existing
        if (Test-ServerHealth) { Set-LauncherState 'Running' 'reconnected' }
        else { $script:StartupDeadline = (Get-Date).AddSeconds(30); Set-LauncherState 'Starting' 'reconnected; health pending' }
        return $true
    } catch {
        Write-TrayRuntimeError $_
        Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
        $script:Process = $null
        return $false
    }
}

function Start-QwenServer {
    if ($script:Process) { try { $script:Process.Refresh(); if (-not $script:Process.HasExited) { return } } catch { $script:Process = $null } }
    try {
        $exe = Resolve-LlamaServer
        $serverArgs = Get-ServerArguments
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeProfile = $script:CurrentProfile -replace '[^A-Za-z0-9._-]', '_'
        $stdout = Join-Path $script:LogDir "$stamp-$safeProfile.stdout.log"
        $stderr = Join-Path $script:LogDir "$stamp-$safeProfile.stderr.log"
        $quoted = @($serverArgs | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' '
        "[$(Get-Date -Format o)] $exe $quoted" | Set-Content -LiteralPath (Join-Path $script:LogDir 'last-command.txt') -Encoding UTF8
        $process = Start-Process -FilePath $exe -ArgumentList $quoted -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
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
        $script:NotifyIcon.ShowBalloonTip(5000,'Qwen Local Launcher',$_.Exception.Message,[Windows.Forms.ToolTipIcon]::Error)
    }
}

function Get-ProcessTreeIds {
    param([Parameter(Mandatory)][int]$RootPid)
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId,ParentProcessId)
    $result = New-Object Collections.Generic.List[int]
    $queue = New-Object Collections.Generic.Queue[int]
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $result.Contains($parent)) { $result.Add($parent) }
        foreach ($child in $all | Where-Object { [int]$_.ParentProcessId -eq $parent }) { $queue.Enqueue([int]$child.ProcessId) }
    }
    return @($result)
}

function Test-AnyProcessAlive {
    param([int[]]$ProcessIds)
    foreach ($processId in $ProcessIds) { if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { return $true } }
    return $false
}

function Stop-QwenServer {
    param([switch]$ForRestart)
    $script:Stopping = $true
    $success = $true
    try {
        if (-not $script:Process) { [void](Connect-ExistingQwenServer) }
        if ($script:Process) {
            $script:Process.Refresh()
            $rootPid = $script:Process.Id
            try { $treeIds = @(Get-ProcessTreeIds -RootPid $rootPid) } catch { Write-TrayRuntimeError $_; $treeIds = @($rootPid) }
            if (Test-AnyProcessAlive $treeIds) {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $rootPid /T 2>$null | Out-Null
                $deadline = (Get-Date).AddSeconds([int]$script:Config.StopTimeoutSeconds)
                while ((Get-Date) -lt $deadline -and (Test-AnyProcessAlive $treeIds)) { Start-Sleep -Milliseconds 200 }
            }
            if (Test-AnyProcessAlive $treeIds) {
                for ($i = $treeIds.Count - 1; $i -ge 0; $i--) {
                    $processId = [int]$treeIds[$i]
                    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { & "$env:SystemRoot\System32\taskkill.exe" /PID $processId /T /F 2>$null | Out-Null }
                }
                Start-Sleep -Milliseconds 500
            }
            if (Test-AnyProcessAlive $treeIds) {
                $success = $false
                $survivors = @($treeIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }) -join ', '
                throw "Could not stop the full llama.cpp process tree. Surviving PID(s): $survivors"
            }
        }
    } catch {
        $success = $false
        Write-TrayRuntimeError $_
        try { Set-LauncherState 'Error' 'stop failed; see logs' } catch {}
        try { $script:NotifyIcon.ShowBalloonTip(5000,'Could not stop llama.cpp',$_.Exception.Message,[Windows.Forms.ToolTipIcon]::Error) } catch {}
    } finally {
        if ($success) {
            Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
            $script:Process = $null
            $script:StartupDeadline = $null
            if (-not $ForRestart) { Set-LauncherState 'Stopped' $null }
        }
        $script:Stopping = $false
    }
    return $success
}

function Restart-QwenServer { if (Stop-QwenServer -ForRestart) { Start-QwenServer } }

function Change-LlamaServer {
    if ($script:ChangingLlama) { return }
    $script:ChangingLlama = $true
    $wasRunning = $script:Process -and -not $script:Process.HasExited
    $oldConfig = $script:Config
    try {
        Set-LauncherState $script:State 'changing llama.cpp'
        if ($wasRunning -and -not (Stop-QwenServer -ForRestart)) { throw 'Could not stop llama.cpp before changing build.' }
        $setupScript = Join-Path $script:Root 'scripts\configure-llama.ps1'
        $setup = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$setupScript) -Wait -PassThru
        if ($setup.ExitCode -eq 0) { Reload-LauncherConfig; Set-LauncherState 'Stopped' $null }
        else { $script:Config = $oldConfig; Set-LauncherState 'Stopped' 'change cancelled' }
    } catch { Write-TrayRuntimeError $_; $script:Config = $oldConfig; Set-LauncherState 'Error' $_.Exception.Message }
    finally { $script:ChangingLlama = $false; Set-LauncherState $script:State $null; if ($wasRunning -and -not $script:Process) { Start-QwenServer } }
}

function Open-WebUi { Start-Process "http://$($script:Config.Host):$($script:Config.Port)/" }
function Open-Logs { Start-Process 'explorer.exe' -ArgumentList $script:LogDir }
function Open-RuntimeDiagnostics {
    $diag = Join-Path $script:Root 'scripts\runtime-diagnostics.ps1'
    $diagArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$diag,'-Root',$script:Root,'-HostAddress',[string]$script:Config.Host,'-Port',[string]$script:Config.Port,'-Profile',$script:CurrentProfile)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $diagArgs | Out-Null
}
function Get-StartupShortcutPath { return Join-Path ([Environment]::GetFolderPath('Startup')) 'Qwen Local Launcher.lnk' }
function Test-StartupEnabled { return Test-Path -LiteralPath (Get-StartupShortcutPath) }
function Set-StartupEnabled {
    param([bool]$Enabled)
    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        try { $shortcut = $shell.CreateShortcut($shortcutPath); $shortcut.TargetPath = Join-Path $script:Root 'scripts\launch-hidden.vbs'; $shortcut.WorkingDirectory = $script:Root; $shortcut.Description = 'Qwen Local Launcher'; $shortcut.Save() }
        finally { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
    } else { Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue }
    $script:StartupButton.IsChecked = Test-StartupEnabled
}
function Exit-Launcher {
    $script:Timer.Stop()
    if (-not (Stop-QwenServer)) { $script:Timer.Start(); return }
    $script:Popup.Hide()
    $script:NotifyIcon.Visible = $false
    if ($script:NotifyIcon.Icon) { $script:NotifyIcon.Icon.Dispose() }
    $script:NotifyIcon.Dispose(); $script:Popup.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose(); [Windows.Forms.Application]::Exit()
}

$script:Popup = New-QwenPopupForm
$script:StatusLabel = New-QwenPopupLabel -Text '' -Size 10.5 -Bold $true
$script:LlamaLabel = New-QwenPopupLabel -Text '' -Size 9 -Color $script:QwenMuted
$script:Divider1 = New-QwenPopupDivider; $script:Divider2 = New-QwenPopupDivider; $script:Divider3 = New-QwenPopupDivider; $script:Divider4 = New-QwenPopupDivider
foreach ($control in @($script:StatusLabel,$script:LlamaLabel,$script:Divider1,$script:Divider2,$script:Divider3,$script:Divider4)) { $script:Popup.Controls.Add($control) }

$script:StartButton = New-QwenPopupButton 'Start server'
$script:StopButton = New-QwenPopupButton 'Stop server'
$script:RestartButton = New-QwenPopupButton 'Restart server'
$script:ProfileButton = New-QwenPopupButton 'Profile' -SecondaryText $script:CurrentProfile -Chevron
$script:ChangeLlamaButton = New-QwenPopupButton 'Change llama.cpp...'
$script:WebButton = New-QwenPopupButton 'Open Web UI'
$script:DiagnosticsButton = New-QwenPopupButton 'Runtime diagnostics' -SecondaryText 'Live'
$script:LogsButton = New-QwenPopupButton 'Open logs'
$script:StartupButton = New-QwenPopupButton 'Launch at Windows startup' -SecondaryText 'Tray only'
$script:AboutButton = New-QwenPopupButton 'About'
$script:QuitButton = New-QwenPopupButton 'Quit'
foreach ($button in @($script:StartButton,$script:StopButton,$script:RestartButton,$script:ProfileButton,$script:ChangeLlamaButton,$script:WebButton,$script:DiagnosticsButton,$script:LogsButton,$script:StartupButton,$script:AboutButton,$script:QuitButton)) { $script:Popup.Controls.Add($button) }

$script:ProfileOrder = if ($script:Config.ProfileOrder) { @($script:Config.ProfileOrder) } else { @($script:Config.Profiles.Keys) }
foreach ($profileName in $script:ProfileOrder) {
    if (-not $script:Config.Profiles.Contains([string]$profileName)) { continue }
    $button = New-QwenPopupButton ([string]$profileName)
    $button.Visible = $false
    $button.add_Click({ $script:CurrentProfile = $this.Text; $script:ProfileExpanded = $false; Set-LauncherState $script:State $null; Update-PopupLayout })
    $script:ProfileButtons[[string]$profileName] = $button
    $script:Popup.Controls.Add($button)
}

$script:StartButton.add_Click({ $script:Popup.Hide(); Start-QwenServer })
$script:StopButton.add_Click({ $script:Popup.Hide(); [void](Stop-QwenServer) })
$script:RestartButton.add_Click({ $script:Popup.Hide(); Restart-QwenServer })
$script:ProfileButton.add_Click({ $script:ProfileExpanded = -not $script:ProfileExpanded; Update-PopupLayout })
$script:ChangeLlamaButton.add_Click({ $script:Popup.Hide(); Change-LlamaServer })
$script:WebButton.add_Click({ $script:Popup.Hide(); Open-WebUi })
$script:DiagnosticsButton.add_Click({ $script:Popup.Hide(); Open-RuntimeDiagnostics })
$script:LogsButton.add_Click({ $script:Popup.Hide(); Open-Logs })
$script:StartupButton.add_Click({ Set-StartupEnabled (-not (Test-StartupEnabled)) })
$script:AboutButton.add_Click({
    $script:Popup.Hide(); $llama = try { Resolve-LlamaServer } catch { 'Not configured' }
    [Windows.Forms.MessageBox]::Show("Qwen Local Launcher`r`n`r`nProfile: $($script:CurrentProfile)`r`nllama.cpp: $llama",'About Qwen Local Launcher',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})
$script:QuitButton.add_Click({ Exit-Launcher })
$script:Popup.add_Deactivate({ if (-not $script:Popup.ContainsFocus) { $script:Popup.Hide() } })

$script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
try {
    $brandPathVar = Get-Variable -Name QwenTrayIconPath -Scope Script -ErrorAction SilentlyContinue
    if ($brandPathVar -and (Get-Command New-QwenBrandIcon -ErrorAction SilentlyContinue)) { $script:QwenBrandIcon = New-QwenBrandIcon -IconPath ([string]$brandPathVar.Value); $script:NotifyIcon.Icon = $script:QwenBrandIcon }
} catch { Write-TrayRuntimeError $_ }
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.add_MouseUp({ if ($_.Button -eq [Windows.Forms.MouseButtons]::Right) { $script:StartupButton.IsChecked = Test-StartupEnabled; Update-PopupLayout; Show-QwenPopupAtCursor -Form $script:Popup } })
$script:NotifyIcon.add_DoubleClick({ if ($script:State -eq 'Running') { Open-WebUi } else { Start-QwenServer } })

$script:Timer = New-Object Windows.Forms.Timer
$script:Timer.Interval = [int]$script:Config.PollIntervalMilliseconds
$script:Timer.add_Tick({
    try {
        if ($script:Process) {
            $script:Process.Refresh()
            if ($script:Process.HasExited) {
                $exitCode = $script:Process.ExitCode; Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue; $script:Process = $null
                if (-not $script:Stopping -and -not $script:ChangingLlama) { Set-LauncherState 'Error' "llama-server exited ($exitCode)"; $script:NotifyIcon.ShowBalloonTip(5000,'Qwen server stopped',"llama-server exited with code $exitCode. Open logs for details.",[Windows.Forms.ToolTipIcon]::Error) }
                return
            }
        }
        if ($script:State -eq 'Starting') {
            if (Test-ServerHealth) { Set-LauncherState 'Running' $script:CurrentProfile; $script:NotifyIcon.ShowBalloonTip(2500,'Qwen is ready',"$($script:CurrentProfile) is serving on port $($script:Config.Port).",[Windows.Forms.ToolTipIcon]::Info) }
            elseif ($script:StartupDeadline -and (Get-Date) -gt $script:StartupDeadline) { Set-LauncherState 'Error' 'health check timed out' }
        } elseif ($script:State -eq 'Running' -and -not (Test-ServerHealth)) { Set-LauncherState 'Starting' 'health check pending'; $script:StartupDeadline = (Get-Date).AddSeconds(15) }
    } catch { Write-TrayRuntimeError $_; try { Set-LauncherState 'Error' 'tray monitor error; see logs' } catch {} }
})

Update-PopupLayout
Set-LauncherState 'Stopped' $null
$script:StartupButton.IsChecked = Test-StartupEnabled
[void](Connect-ExistingQwenServer)
$script:Timer.Start()
if ($StartImmediately -and -not $script:Process) { Start-QwenServer }
try { [Windows.Forms.Application]::Run() }
finally { if ($script:NotifyIcon -and $script:NotifyIcon.Visible) { Exit-Launcher } }
