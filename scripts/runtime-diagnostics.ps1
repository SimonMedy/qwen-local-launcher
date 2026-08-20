#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$HostAddress = '127.0.0.1',
    [int]$Port = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logDir = Join-Path $Root 'logs'
$pidPath = Join-Path $Root 'runtime\llama-server.pid'
$surface = [Drawing.Color]::FromArgb(22, 23, 26)
$panel = [Drawing.Color]::FromArgb(31, 32, 36)
$text = [Drawing.Color]::FromArgb(242, 244, 247)
$muted = [Drawing.Color]::FromArgb(158, 164, 174)
$accent = [Drawing.Color]::FromArgb(90, 183, 255)

function Get-JsonEndpoint {
    param([string]$Path)
    try {
        return Invoke-RestMethod -Uri "http://${HostAddress}:$Port$Path" -TimeoutSec 1
    } catch { return $null }
}

function Get-CurrentProcessInfo {
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $null }
    try {
        $serverPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
        $p = Get-Process -Id $serverPid -ErrorAction Stop
        return [pscustomobject]@{
            Pid = $p.Id
            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
            PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
            CpuSeconds = [math]::Round($p.CPU, 1)
            Threads = $p.Threads.Count
            Started = $p.StartTime
        }
    } catch { return $null }
}

function Get-ImportantLogLines {
    $latest = Get-ChildItem -LiteralPath $logDir -Filter '*.stderr.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return 'No llama.cpp stderr log found yet.' }

    $patterns = @(
        'offload', 'buffer size', 'KV', 'compute', 'Vulkan', 'CUDA', 'ROCm', 'HIP',
        'mmproj', 'vision', 'draft', 'MTP', 'speculat', 'context', 'n_ctx', 'cache',
        'model size', 'repack', 'flash', 'slot', 'prompt eval', 'eval time', 'tokens per second'
    )
    $regex = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $lines = Select-String -LiteralPath $latest.FullName -Pattern $regex -CaseSensitive:$false -ErrorAction SilentlyContinue |
        Select-Object -Last 140 | ForEach-Object { $_.Line }
    if (-not $lines) { return "No matching runtime lines yet.`r`nLog: $($latest.Name)" }
    return "Log: $($latest.Name)`r`n`r`n" + ($lines -join "`r`n")
}

function Get-CommandText {
    $path = Join-Path $logDir 'last-command.txt'
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    return 'No command recorded yet.'
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Qwen Local Launcher — Runtime diagnostics'
$form.Size = New-Object Drawing.Size(980, 760)
$form.MinimumSize = New-Object Drawing.Size(820, 620)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $surface
$form.ForeColor = $text
$form.Font = New-Object Drawing.Font('Segoe UI', 9.5)

$top = New-Object Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 94; $top.Padding = New-Object Windows.Forms.Padding(20,16,20,12); $top.BackColor = $panel
$form.Controls.Add($top)

$title = New-Object Windows.Forms.Label
$title.Text = 'Runtime diagnostics'; $title.AutoSize = $true; $title.ForeColor = $text
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
$title.Location = New-Object Drawing.Point(20,14)
$top.Controls.Add($title)

$status = New-Object Windows.Forms.Label
$status.AutoSize = $true; $status.ForeColor = $accent; $status.Location = New-Object Drawing.Point(22,52)
$top.Controls.Add($status)

$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = 'Refresh'; $refreshButton.Size = New-Object Drawing.Size(92,32)
$refreshButton.Anchor = 'Top,Right'; $refreshButton.Location = New-Object Drawing.Point(848,28)
$refreshButton.FlatStyle = 'Flat'; $refreshButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(66,69,76)
$refreshButton.BackColor = [Drawing.Color]::FromArgb(42,44,49); $refreshButton.ForeColor = $text
$top.Controls.Add($refreshButton)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.Padding = New-Object Drawing.Point(14,7)
$form.Controls.Add($tabs)

function New-DarkTab([string]$name) {
    $tab = New-Object Windows.Forms.TabPage
    $tab.Text = $name; $tab.BackColor = $surface; $tab.ForeColor = $text
    [void]$tabs.TabPages.Add($tab)
    return $tab
}

$overviewTab = New-DarkTab 'Overview'
$llamaTab = New-DarkTab 'llama.cpp memory / timing'
$commandTab = New-DarkTab 'Command'
$slotsTab = New-DarkTab 'Slots JSON'

$overview = New-Object Windows.Forms.TextBox
$overview.Multiline = $true; $overview.ReadOnly = $true; $overview.Dock = 'Fill'; $overview.ScrollBars = 'Vertical'
$overview.BackColor = $surface; $overview.ForeColor = $text; $overview.BorderStyle = 'None'
$overview.Font = New-Object Drawing.Font('Cascadia Mono', 10)
$overviewTab.Padding = New-Object Windows.Forms.Padding(18); $overviewTab.Controls.Add($overview)

$runtime = New-Object Windows.Forms.TextBox
$runtime.Multiline = $true; $runtime.ReadOnly = $true; $runtime.Dock = 'Fill'; $runtime.ScrollBars = 'Both'; $runtime.WordWrap = $false
$runtime.BackColor = $surface; $runtime.ForeColor = $text; $runtime.BorderStyle = 'None'
$runtime.Font = New-Object Drawing.Font('Cascadia Mono', 9.5)
$llamaTab.Padding = New-Object Windows.Forms.Padding(18); $llamaTab.Controls.Add($runtime)

$command = New-Object Windows.Forms.TextBox
$command.Multiline = $true; $command.ReadOnly = $true; $command.Dock = 'Fill'; $command.ScrollBars = 'Both'; $command.WordWrap = $true
$command.BackColor = $surface; $command.ForeColor = $text; $command.BorderStyle = 'None'
$command.Font = New-Object Drawing.Font('Cascadia Mono', 9.5)
$commandTab.Padding = New-Object Windows.Forms.Padding(18); $commandTab.Controls.Add($command)

$slotsBox = New-Object Windows.Forms.TextBox
$slotsBox.Multiline = $true; $slotsBox.ReadOnly = $true; $slotsBox.Dock = 'Fill'; $slotsBox.ScrollBars = 'Both'; $slotsBox.WordWrap = $false
$slotsBox.BackColor = $surface; $slotsBox.ForeColor = $text; $slotsBox.BorderStyle = 'None'
$slotsBox.Font = New-Object Drawing.Font('Cascadia Mono', 9.5)
$slotsTab.Padding = New-Object Windows.Forms.Padding(18); $slotsTab.Controls.Add($slotsBox)

function Update-Diagnostics {
    try {
        $health = Get-JsonEndpoint '/health'
        $slots = Get-JsonEndpoint '/slots'
        $proc = Get-CurrentProcessInfo
        $healthText = if ($health) { if ($health.status) { [string]$health.status } else { 'responding' } } else { 'offline / unavailable' }
        $status.Text = "Health: $healthText    •    Endpoint: http://${HostAddress}:$Port"

        $lines = New-Object Collections.Generic.List[string]
        $lines.Add("SERVER")
        $lines.Add("  Health       : $healthText")
        $lines.Add("  Endpoint     : http://${HostAddress}:$Port")
        if ($proc) {
            $lines.Add("  PID          : $($proc.Pid)")
            $lines.Add("  Working set  : $($proc.WorkingSetMB) MB")
            $lines.Add("  Private mem  : $($proc.PrivateMB) MB")
            $lines.Add("  CPU time     : $($proc.CpuSeconds) s")
            $lines.Add("  Threads      : $($proc.Threads)")
            $lines.Add("  Started      : $($proc.Started)")
        } else {
            $lines.Add('  Process      : not found from launcher PID file')
        }
        $lines.Add('')
        $lines.Add('SLOTS / CONTEXT')
        if ($slots) {
            $slotList = @($slots)
            $lines.Add("  Slot count   : $($slotList.Count)")
            foreach ($slot in $slotList) {
                $id = if ($null -ne $slot.id) { $slot.id } else { '?' }
                $state = if ($slot.is_processing) { 'processing' } else { 'idle' }
                $ctx = if ($slot.n_ctx) { $slot.n_ctx } elseif ($slot.n_ctx_train) { $slot.n_ctx_train } else { '?' }
                $used = if ($null -ne $slot.n_tokens) { $slot.n_tokens } else { '?' }
                $lines.Add("  Slot $id       : $state | tokens=$used | context=$ctx")
            }
        } else {
            $lines.Add('  /slots unavailable')
        }
        $overview.Text = $lines -join "`r`n"
        $runtime.Text = Get-ImportantLogLines
        $command.Text = Get-CommandText
        $slotsBox.Text = if ($slots) { $slots | ConvertTo-Json -Depth 12 } else { 'No /slots response.' }
    } catch {
        $status.Text = "Diagnostics refresh error: $($_.Exception.Message)"
    }
}

$refreshButton.add_Click({ Update-Diagnostics })
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({ Update-Diagnostics })
$form.add_Shown({ Update-Diagnostics; $timer.Start() })
$form.add_FormClosed({ $timer.Stop(); $timer.Dispose() })
[void]$form.ShowDialog()
