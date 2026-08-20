#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$HostAddress = '127.0.0.1',
    [int]$Port = 8080,
    [string]$Profile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logDir = Join-Path $Root 'logs'
$pidPath = Join-Path $Root 'runtime\llama-server.pid'
$surface = [Drawing.Color]::FromArgb(20, 21, 24)
$panel = [Drawing.Color]::FromArgb(28, 29, 33)
$card = [Drawing.Color]::FromArgb(34, 35, 40)
$text = [Drawing.Color]::FromArgb(242, 243, 245)
$muted = [Drawing.Color]::FromArgb(156, 163, 175)
$accent = [Drawing.Color]::FromArgb(88, 184, 255)
$divider = [Drawing.Color]::FromArgb(56, 58, 65)

function Get-SafeProperty {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-JsonEndpoint {
    param([string]$Path)
    try { return Invoke-RestMethod -Uri "http://${HostAddress}:$Port$Path" -TimeoutSec 2 }
    catch { return $null }
}

function Get-TextEndpoint {
    param([string]$Path)
    try { return [string](Invoke-WebRequest -Uri "http://${HostAddress}:$Port$Path" -UseBasicParsing -TimeoutSec 2).Content }
    catch { return $null }
}

function Get-CurrentProcessInfo {
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $null }
    try {
        $serverPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
        $p = Get-Process -Id $serverPid -ErrorAction Stop
        $gpuDedicated = $null
        $gpuShared = $null
        try {
            $gpuRows = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction Stop |
                Where-Object { $_.Name -match "pid_${serverPid}_" })
            if ($gpuRows.Count -gt 0) {
                $gpuDedicated = [math]::Round((($gpuRows | Measure-Object DedicatedUsage -Sum).Sum) / 1MB, 1)
                $gpuShared = [math]::Round((($gpuRows | Measure-Object SharedUsage -Sum).Sum) / 1MB, 1)
            }
        } catch {}
        return [pscustomobject]@{
            Pid = $p.Id
            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
            PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
            CpuSeconds = [math]::Round($p.CPU, 1)
            Threads = $p.Threads.Count
            Started = $p.StartTime
            GpuDedicatedMB = $gpuDedicated
            GpuSharedMB = $gpuShared
        }
    } catch { return $null }
}

function Get-SystemMemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
        $totalMB = [math]::Round([double]$os.TotalVisibleMemorySize / 1024, 0)
        $availableMB = [math]::Round([double]$os.FreePhysicalMemory / 1024, 0)
        $usedMB = $totalMB - $availableMB
        $commitMB = $null
        $commitLimitMB = $null
        if ($perf) {
            $commitMB = [math]::Round([double]$perf.CommittedBytes / 1MB, 0)
            $commitLimitMB = [math]::Round([double]$perf.CommitLimit / 1MB, 0)
        }
        return [pscustomobject]@{ TotalMB=$totalMB; UsedMB=$usedMB; AvailableMB=$availableMB; CommitMB=$commitMB; CommitLimitMB=$commitLimitMB }
    } catch { return $null }
}

function Get-LatestStderrLog {
    return Get-ChildItem -LiteralPath $logDir -Filter '*.stderr.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-CommandText {
    $path = Join-Path $logDir 'last-command.txt'
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    return 'No command recorded yet.'
}

function Get-ModelInfo {
    $models = Get-JsonEndpoint '/v1/models'
    if (-not $models) { return $null }
    $data = @(Get-SafeProperty $models 'data' @())
    if ($data.Count -eq 0) { return $null }
    return $data[0]
}

function Get-LogAnalysis {
    $latest = Get-LatestStderrLog
    if (-not $latest) {
        return [pscustomobject]@{ Summary='No llama.cpp stderr log found yet.'; Raw='No llama.cpp stderr log found yet.' }
    }
    $all = @(Get-Content -LiteralPath $latest.FullName -ErrorAction SilentlyContinue)
    $importantRegex = '(?i)(offload|buffer size|KV|compute|Vulkan|CUDA|ROCm|HIP|mmproj|mtmd|vision|draft|MTP|speculat|context|n_ctx|cache|model size|flash.attn|flash_attn|prompt eval|eval time|tokens per second|load_tensors|repack)'
    $important = @($all | Where-Object { $_ -match $importantRegex })

    $gpuModel = 0.0; $cpuModel = 0.0; $kv = 0.0; $compute = 0.0; $output = 0.0
    foreach ($line in $important) {
        if ($line -match '(?i)(?<device>[A-Za-z0-9_]+)\s+model buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') {
            $value = [double]$matches.size
            if ($matches.device -match '(?i)CPU|Host') { $cpuModel += $value } else { $gpuModel += $value }
        }
        if ($line -match '(?i)KV buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $kv += [double]$matches.size }
        if ($line -match '(?i)compute buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $compute += [double]$matches.size }
        if ($line -match '(?i)output buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $output += [double]$matches.size }
    }

    $summary = New-Object Collections.Generic.List[string]
    $summary.Add("Source log            : $($latest.Name)")
    if ($gpuModel -gt 0) { $summary.Add(('Model buffers GPU     : {0:N1} MiB' -f $gpuModel)) }
    if ($cpuModel -gt 0) { $summary.Add(('Model buffers CPU     : {0:N1} MiB' -f $cpuModel)) }
    if ($kv -gt 0) { $summary.Add(('KV buffers reported   : {0:N1} MiB' -f $kv)) }
    if ($compute -gt 0) { $summary.Add(('Compute buffers       : {0:N1} MiB' -f $compute)) }
    if ($output -gt 0) { $summary.Add(('Output buffers        : {0:N1} MiB' -f $output)) }

    $offloadLines = @($important | Where-Object { $_ -match '(?i)offload|GPU layers|layers to GPU' } | Select-Object -Last 8)
    $mmprojLines = @($important | Where-Object { $_ -match '(?i)mmproj|mtmd|vision' } | Select-Object -Last 8)
    $mtpLines = @($important | Where-Object { $_ -match '(?i)draft|MTP|speculat' } | Select-Object -Last 10)
    if ($offloadLines.Count -gt 0) { $summary.Add(''); $summary.Add('OFFLOAD'); $offloadLines | ForEach-Object { $summary.Add("  $_") } }
    if ($mmprojLines.Count -gt 0) { $summary.Add(''); $summary.Add('MULTIMODAL'); $mmprojLines | ForEach-Object { $summary.Add("  $_") } }
    if ($mtpLines.Count -gt 0) { $summary.Add(''); $summary.Add('MTP / SPECULATIVE'); $mtpLines | ForEach-Object { $summary.Add("  $_") } }

    return [pscustomobject]@{
        Summary = $summary -join "`r`n"
        Raw = if ($important.Count -gt 0) { ($important | Select-Object -Last 220) -join "`r`n" } else { 'No matching memory/offload/timing lines yet.' }
    }
}

function Get-MetricsSummary {
    param([string]$Metrics)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { return 'Metrics unavailable. Restart the server with this launcher version to enable --metrics.' }
    $wanted = @($Metrics -split "`n" | Where-Object {
        $_ -notmatch '^#' -and $_ -match '(?i)(tokens|prompt|predicted|requests|seconds|n_tokens|max|cache|draft|speculat)'
    })
    if ($wanted.Count -eq 0) { return 'Metrics endpoint responded, but no selected counters matched.' }
    return ($wanted | Select-Object -Last 120) -join "`r`n"
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Qwen Local Launcher - Runtime diagnostics'
$form.Size = New-Object Drawing.Size(1080, 800)
$form.MinimumSize = New-Object Drawing.Size(900, 680)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $surface
$form.ForeColor = $text
$form.Font = New-Object Drawing.Font('Segoe UI', 9.5)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 92; $header.BackColor = $panel
$form.Controls.Add($header)
$title = New-Object Windows.Forms.Label
$title.Text = 'Runtime diagnostics'; $title.AutoSize = $true; $title.ForeColor = $text; $title.Font = New-Object Drawing.Font('Segoe UI Semibold',16); $title.Location = New-Object Drawing.Point(22,14)
$header.Controls.Add($title)
$status = New-Object Windows.Forms.Label
$status.AutoSize = $true; $status.ForeColor = $accent; $status.Location = New-Object Drawing.Point(24,53)
$header.Controls.Add($status)
$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = 'Refresh'; $refreshButton.Size = New-Object Drawing.Size(92,32); $refreshButton.Anchor = 'Top,Right'; $refreshButton.Location = New-Object Drawing.Point(956,27)
$refreshButton.FlatStyle = 'Flat'; $refreshButton.FlatAppearance.BorderSize = 0; $refreshButton.BackColor = $card; $refreshButton.ForeColor = $text
$header.Controls.Add($refreshButton)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.Padding = New-Object Drawing.Point(14,7)
$form.Controls.Add($tabs)

function New-DarkTab([string]$Name) {
    $tab = New-Object Windows.Forms.TabPage
    $tab.Text = $Name; $tab.BackColor = $surface; $tab.ForeColor = $text
    [void]$tabs.TabPages.Add($tab); return $tab
}
function New-DiagnosticBox([Windows.Forms.TabPage]$Tab, [bool]$WordWrap = $false) {
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.Dock = 'Fill'; $box.ScrollBars = 'Both'; $box.WordWrap = $WordWrap
    $box.BackColor = $surface; $box.ForeColor = $text; $box.BorderStyle = 'None'; $box.Font = New-Object Drawing.Font('Consolas',10)
    $Tab.Padding = New-Object Windows.Forms.Padding(18); $Tab.Controls.Add($box); return $box
}

$overviewBox = New-DiagnosticBox (New-DarkTab 'Overview') $false
$memoryBox = New-DiagnosticBox (New-DarkTab 'Memory / offload') $false
$performanceBox = New-DiagnosticBox (New-DarkTab 'Performance') $false
$commandBox = New-DiagnosticBox (New-DarkTab 'Command') $true
$slotsBox = New-DiagnosticBox (New-DarkTab 'Slots JSON') $false
$rawBox = New-DiagnosticBox (New-DarkTab 'Raw llama.cpp') $false

function Update-Diagnostics {
    try {
        $health = Get-JsonEndpoint '/health'
        $slotsResponse = Get-JsonEndpoint '/slots'
        $slots = if ($null -eq $slotsResponse) { @() } else { @($slotsResponse) }
        $metrics = Get-TextEndpoint '/metrics'
        $proc = Get-CurrentProcessInfo
        $system = Get-SystemMemoryInfo
        $model = Get-ModelInfo
        $analysis = Get-LogAnalysis
        $healthStatus = [string](Get-SafeProperty $health 'status' 'offline')
        if ([string]::IsNullOrWhiteSpace($healthStatus)) { $healthStatus = if ($health) { 'responding' } else { 'offline' } }
        $status.Text = "Health: $healthStatus    Endpoint: http://${HostAddress}:$Port    Profile: $Profile"

        $overview = New-Object Collections.Generic.List[string]
        $overview.Add('SERVER')
        $overview.Add("  Health              : $healthStatus")
        $overview.Add("  Endpoint            : http://${HostAddress}:$Port")
        if ($Profile) { $overview.Add("  Launcher profile    : $Profile") }
        if ($proc) {
            $overview.Add("  PID                 : $($proc.Pid)")
            $overview.Add("  Working set         : $($proc.WorkingSetMB) MB")
            $overview.Add("  Private memory      : $($proc.PrivateMB) MB")
            if ($null -ne $proc.GpuDedicatedMB) { $overview.Add("  GPU dedicated (PID) : $($proc.GpuDedicatedMB) MB") }
            if ($null -ne $proc.GpuSharedMB) { $overview.Add("  GPU shared (PID)    : $($proc.GpuSharedMB) MB") }
            $overview.Add("  CPU time            : $($proc.CpuSeconds) s")
            $overview.Add("  Threads             : $($proc.Threads)")
        } else { $overview.Add('  Process             : not found from launcher PID file') }
        if ($system) {
            $overview.Add('')
            $overview.Add('SYSTEM MEMORY')
            $overview.Add("  RAM used            : $($system.UsedMB) / $($system.TotalMB) MB")
            $overview.Add("  RAM available       : $($system.AvailableMB) MB")
            if ($null -ne $system.CommitMB) { $overview.Add("  Commit              : $($system.CommitMB) / $($system.CommitLimitMB) MB") }
        }
        if ($model) {
            $meta = Get-SafeProperty $model 'meta' $null
            $overview.Add('')
            $overview.Add('MODEL')
            $overview.Add("  ID                  : $(Get-SafeProperty $model 'id' '?')")
            if ($meta) {
                $params = Get-SafeProperty $meta 'n_params' $null
                $size = Get-SafeProperty $meta 'size' $null
                $ctxTrain = Get-SafeProperty $meta 'n_ctx_train' $null
                if ($params) { $overview.Add(('  Parameters          : {0:N2} B' -f ([double]$params / 1e9))) }
                if ($size) { $overview.Add(('  Model file size     : {0:N2} GiB' -f ([double]$size / 1GB))) }
                if ($ctxTrain) { $overview.Add("  Training context    : $ctxTrain") }
            }
        }
        $overview.Add('')
        $overview.Add('SLOTS / CONTEXT')
        if ($slots.Count -eq 0) { $overview.Add('  No slot data available.') }
        foreach ($slot in $slots) {
            $id = Get-SafeProperty $slot 'id' '?'
            $ctx = Get-SafeProperty $slot 'n_ctx' '?'
            $processing = [bool](Get-SafeProperty $slot 'is_processing' $false)
            $speculative = [bool](Get-SafeProperty $slot 'speculative' $false)
            $next = Get-SafeProperty $slot 'next_token' $null
            $decoded = Get-SafeProperty $next 'n_decoded' '?'
            $paramsObj = Get-SafeProperty $slot 'params' $null
            $specMax = Get-SafeProperty $paramsObj 'speculative.n_max' $null
            $overview.Add("  Slot $id              : ctx=$ctx | processing=$processing | speculative=$speculative | decoded=$decoded")
            if ($null -ne $specMax) { $overview.Add("    speculative.n_max : $specMax") }
        }
        $overviewBox.Text = $overview -join "`r`n"

        $memory = New-Object Collections.Generic.List[string]
        $memory.Add('LIVE WINDOWS MEMORY')
        if ($proc) {
            $memory.Add("  Process working set  : $($proc.WorkingSetMB) MB")
            $memory.Add("  Process private      : $($proc.PrivateMB) MB")
            $memory.Add("  GPU dedicated (PID)  : $(if ($null -ne $proc.GpuDedicatedMB) { "$($proc.GpuDedicatedMB) MB" } else { 'not exposed by Windows counters' })")
            $memory.Add("  GPU shared (PID)     : $(if ($null -ne $proc.GpuSharedMB) { "$($proc.GpuSharedMB) MB" } else { 'not exposed by Windows counters' })")
        }
        if ($system) {
            $memory.Add("  System RAM used      : $($system.UsedMB) / $($system.TotalMB) MB")
            $memory.Add("  System RAM available : $($system.AvailableMB) MB")
            if ($null -ne $system.CommitMB) { $memory.Add("  System commit        : $($system.CommitMB) / $($system.CommitLimitMB) MB") }
        }
        $memory.Add('')
        $memory.Add('LLAMA.CPP STARTUP ALLOCATION')
        $memory.Add($analysis.Summary)
        $memoryBox.Text = $memory -join "`r`n"

        $performanceBox.Text = (Get-MetricsSummary $metrics) + "`r`n`r`nRECENT TIMING / SLOT LOGS`r`n" + (($analysis.Raw -split "`r?`n" | Where-Object { $_ -match '(?i)prompt eval|eval time|tokens per second|slot|draft|speculat' } | Select-Object -Last 100) -join "`r`n")
        $commandBox.Text = Get-CommandText
        $slotsBox.Text = if ($slotsResponse) { $slotsResponse | ConvertTo-Json -Depth 20 } else { 'No /slots response.' }
        $rawBox.Text = $analysis.Raw
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
