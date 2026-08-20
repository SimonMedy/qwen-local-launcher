#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$HostAddress = '127.0.0.1',
    [int]$Port = 8080,
    [string]$Profile = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:LogDir = Join-Path $Root 'logs'
$script:PidPath = Join-Path $Root 'runtime\llama-server.pid'
$script:ErrorLog = Join-Path $script:LogDir 'runtime-diagnostics-error.log'

function Write-DiagnosticsError {
    param([object]$ErrorRecord)
    try {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        Add-Content -LiteralPath $script:ErrorLog -Encoding UTF8 -Value "[$(Get-Date -Format o)] $($ErrorRecord | Out-String)"
    } catch {}
}

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

function Get-CommandText {
    $path = Join-Path $script:LogDir 'last-command.txt'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    return 'No command recorded yet.'
}

function Get-CommandFlagValue {
    param([string]$Command, [string]$Flag)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $pattern = '(?:^|\s)' + [regex]::Escape($Flag) + '\s+(?:"(?<quoted>[^"]+)"|(?<plain>\S+))'
    $match = [regex]::Match($Command, $pattern)
    if (-not $match.Success) { return $null }
    if ($match.Groups['quoted'].Success) { return $match.Groups['quoted'].Value }
    return $match.Groups['plain'].Value
}

function Get-LatestStderrLog {
    return Get-ChildItem -LiteralPath $script:LogDir -Filter '*.stderr.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-CurrentProcessInfo {
    if (-not (Test-Path -LiteralPath $script:PidPath -PathType Leaf)) { return $null }
    try {
        $pidValue = [int](Get-Content -LiteralPath $script:PidPath -Raw).Trim()
        $process = Get-Process -Id $pidValue -ErrorAction Stop
        $dedicated = $null
        $shared = $null
        try {
            [object[]]$rows = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction Stop | Where-Object { $_.Name -match "pid_${pidValue}_" })
            if ($rows.Length -gt 0) {
                $dedicated = [math]::Round((($rows | Measure-Object DedicatedUsage -Sum).Sum) / 1MB, 1)
                $shared = [math]::Round((($rows | Measure-Object SharedUsage -Sum).Sum) / 1MB, 1)
            }
        } catch {}
        return [pscustomobject]@{
            Pid = $process.Id
            WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
            PrivateMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
            CpuSeconds = [math]::Round($process.CPU, 1)
            Threads = $process.Threads.Count
            GpuDedicatedMB = $dedicated
            GpuSharedMB = $shared
        }
    } catch { return $null }
}

function Get-SystemMemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [math]::Round([double]$os.TotalVisibleMemorySize / 1024, 0)
        $available = [math]::Round([double]$os.FreePhysicalMemory / 1024, 0)
        $commit = $null
        $limit = $null
        try {
            $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
            $commit = [math]::Round([double]$memory.CommittedBytes / 1MB, 0)
            $limit = [math]::Round([double]$memory.CommitLimit / 1MB, 0)
        } catch {}
        return [pscustomobject]@{
            TotalMB = $total
            UsedMB = $total - $available
            AvailableMB = $available
            CommitMB = $commit
            CommitLimitMB = $limit
        }
    } catch { return $null }
}

function Get-DeviceClass {
    param([string]$Device)
    if ($Device -match '(?i)CPU|Host') { return 'CPU' }
    return 'GPU'
}

function Format-MiB {
    param([double]$Value, [bool]$Seen)
    if (-not $Seen) { return 'not captured in current log' }
    return ('{0:N1} MiB' -f $Value)
}

function Get-LogAnalysis {
    param([string[]]$Lines, [string]$SourceName = '')

    if ($null -eq $Lines) {
        $latest = Get-LatestStderrLog
        if (-not $latest) {
            return [pscustomobject]@{ Summary = 'No llama.cpp stderr log found yet.'; Raw = 'No llama.cpp stderr log found yet.' }
        }
        $SourceName = $latest.Name
        [string[]]$Lines = @(Get-Content -LiteralPath $latest.FullName -ErrorAction Stop)
    }

    $totals = @{ GPUModel = 0.0; CPUModel = 0.0; GPUKV = 0.0; CPUKV = 0.0; GPUCompute = 0.0; CPUCompute = 0.0; GPUOutput = 0.0; CPUOutput = 0.0 }
    $seen = @{ GPUModel = $false; CPUModel = $false; GPUKV = $false; CPUKV = $false; GPUCompute = $false; CPUCompute = $false; GPUOutput = $false; CPUOutput = $false }
    $gpuLayers = $null
    $totalLayers = $null
    $runtimeContext = $null
    $runtimeBatch = $null
    $runtimeUbatch = $null
    $mmprojPath = $null
    $mmprojBackend = 'unknown'
    $mtpDetected = $false
    $imageWarning = $false
    $interesting = New-Object Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -match '(?i)(offload|buffer size|KV|compute|Vulkan|CUDA|ROCm|HIP|mmproj|mtmd|CLIP|vision|draft|MTP|speculat|n_ctx|n_batch|n_ubatch|image tokens|prompt eval|eval time|tokens per second|flash)') { $interesting.Add($line) }

        if ($line -match '(?i)(?<device>[A-Za-z0-9_:\[\].-]+)\s+model buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') {
            $class = Get-DeviceClass $matches.device
            $key = "${class}Model"
            $totals[$key] += [double]$matches.size
            $seen[$key] = $true
        }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:\[\].-]+)\s+KV buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') {
            $class = Get-DeviceClass $matches.device
            $key = "${class}KV"
            $totals[$key] += [double]$matches.size
            $seen[$key] = $true
        }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:\[\].-]+)\s+compute buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') {
            $class = Get-DeviceClass $matches.device
            $key = "${class}Compute"
            $totals[$key] += [double]$matches.size
            $seen[$key] = $true
        }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:\[\].-]+)\s+output buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') {
            $class = Get-DeviceClass $matches.device
            $key = "${class}Output"
            $totals[$key] += [double]$matches.size
            $seen[$key] = $true
        }
        if ($line -match '(?i)offloaded\s+(?<gpu>\d+)\s*/\s*(?<total>\d+)\s+layers?\s+to\s+GPU') {
            $gpuLayers = [int]$matches.gpu
            $totalLayers = [int]$matches.total
        }
        if ($line -match '(?i)n_ctx_slot\s*=\s*(?<ctx>\d+)') { $runtimeContext = [int]$matches.ctx }
        elseif ($line -match '(?i)n_ctx(?:_per_seq|_seq)?\s*=\s*(?<ctx>\d+)') { $runtimeContext = [int]$matches.ctx }
        if ($line -match '(?i)n_batch\s*=\s*(?<value>\d+)') { $runtimeBatch = [int]$matches.value }
        if ($line -match '(?i)n_ubatch\s*=\s*(?<value>\d+)') { $runtimeUbatch = [int]$matches.value }
        if ($line -match "(?i)loaded multimodal model,\s*'(?<path>[^']+)'" ) { $mmprojPath = $matches.path }
        if ($line -match '(?i)(CLIP|mtmd).*using\s+(?<backend>.+?)\s+backend') { $mmprojBackend = $matches.backend.Trim() }
        if ($line -match '(?i)draft|MTP|speculat') { $mtpDetected = $true }
        if ($line -match '(?i)require at minimum 1024 image tokens') { $imageWarning = $true }
    }

    $command = Get-CommandText
    $requestedContext = Get-CommandFlagValue $command '-c'
    $fitContext = Get-CommandFlagValue $command '--fit-ctx'
    $requestedBatch = Get-CommandFlagValue $command '-b'
    $requestedUbatch = Get-CommandFlagValue $command '-ub'
    if ($command -match '(?:^|\s)--no-mmproj-offload(?:\s|$)') { $mmprojBackend = 'CPU (--no-mmproj-offload)' }

    $summary = New-Object Collections.Generic.List[string]
    if ($SourceName) { $summary.Add("Source log                 : $SourceName") }
    $summary.Add('')
    $summary.Add('CONTEXT / BATCH')
    $summary.Add("  Requested context        : $(if ($requestedContext) { $requestedContext } else { 'unknown' })")
    $summary.Add("  Auto-fit minimum         : $(if ($fitContext) { $fitContext } else { 'not configured' })")
    $summary.Add("  Runtime context          : $(if ($null -ne $runtimeContext) { $runtimeContext } else { 'not captured' })")
    if ($requestedContext -and $null -ne $runtimeContext -and [int64]$runtimeContext -lt [int64]$requestedContext) { $summary.Add('  WARNING                  : runtime context is below requested context') }
    $summary.Add("  Requested n_batch        : $(if ($requestedBatch) { $requestedBatch } else { 'unknown' })")
    $summary.Add("  Runtime n_batch          : $(if ($null -ne $runtimeBatch) { $runtimeBatch } else { 'not captured' })")
    $summary.Add("  Requested n_ubatch       : $(if ($requestedUbatch) { $requestedUbatch } else { 'unknown' })")
    $summary.Add("  Runtime n_ubatch         : $(if ($null -ne $runtimeUbatch) { $runtimeUbatch } else { 'not captured' })")
    $summary.Add('')
    $summary.Add('MODEL / OFFLOAD')
    $summary.Add("  GPU model buffers        : $(Format-MiB $totals.GPUModel $seen.GPUModel)")
    $summary.Add("  CPU model buffers        : $(Format-MiB $totals.CPUModel $seen.CPUModel)")
    if ($null -ne $gpuLayers) { $summary.Add("  GPU layers               : $gpuLayers / $totalLayers") } else { $summary.Add('  GPU layers               : not captured in current log') }
    $summary.Add('')
    $summary.Add('KV / COMPUTE')
    $summary.Add("  KV GPU                   : $(Format-MiB $totals.GPUKV $seen.GPUKV)")
    $summary.Add("  KV CPU                   : $(Format-MiB $totals.CPUKV $seen.CPUKV)")
    $summary.Add("  Compute GPU              : $(Format-MiB $totals.GPUCompute $seen.GPUCompute)")
    $summary.Add("  Compute CPU              : $(Format-MiB $totals.CPUCompute $seen.CPUCompute)")
    $summary.Add("  Output GPU               : $(Format-MiB $totals.GPUOutput $seen.GPUOutput)")
    $summary.Add("  Output CPU               : $(Format-MiB $totals.CPUOutput $seen.CPUOutput)")
    $summary.Add('')
    $summary.Add('MULTIMODAL / MTP')
    $summary.Add("  mmproj backend           : $mmprojBackend")
    if ($mmprojPath) { $summary.Add("  mmproj file              : $mmprojPath") }
    $summary.Add("  MTP/speculative detected : $mtpDetected")
    $summary.Add("  1024 image-token warning : $imageWarning")

    $raw = 'No matching llama.cpp runtime lines yet.'
    if ($interesting.Count -gt 0) { $raw = ($interesting | Select-Object -Last 400) -join "`r`n" }
    return [pscustomobject]@{ Summary = $summary -join "`r`n"; Raw = $raw }
}

function Get-SlotSummary {
    param($SlotsResponse)
    [object[]]$slots = @()
    if ($null -ne $SlotsResponse) {
        if ($SlotsResponse -is [System.Array]) { [object[]]$slots = $SlotsResponse }
        else { [object[]]$slots = @($SlotsResponse) }
    }
    if ($slots.Length -eq 0) { return 'No slot data available.' }
    $lines = New-Object Collections.Generic.List[string]
    foreach ($slot in $slots) {
        $id = Get-SafeProperty $slot 'id' '?'
        $context = Get-SafeProperty $slot 'n_ctx' '?'
        $processing = Get-SafeProperty $slot 'is_processing' $false
        $nextToken = Get-SafeProperty $slot 'next_token' $null
        $decoded = Get-SafeProperty $nextToken 'n_decoded' '?'
        $prompt = Get-SafeProperty $nextToken 'n_prompt_tokens_processed' '?'
        $lines.Add("Slot $id : context=$context | processing=$processing | decoded=$decoded | prompt_processed=$prompt")
    }
    return $lines -join "`r`n"
}

function Get-MetricsSummary {
    param([string]$Metrics)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { return 'Metrics unavailable. Restart llama-server so --metrics is active.' }
    [string[]]$wanted = @($Metrics -split "`r?`n" | Where-Object { $_ -notmatch '^#' -and $_ -match '(?i)(tokens|prompt|predicted|requests|seconds|cache|draft|speculat|slots)' })
    if ($wanted.Length -eq 0) { return 'Metrics endpoint responded, but no selected counters matched.' }
    $hasTraffic = $false
    foreach ($line in $wanted) {
        if ($line -match '\s([1-9][0-9]*(?:\.[0-9]+)?)$') { $hasTraffic = $true; break }
    }
    $prefix = ''
    if (-not $hasTraffic) { $prefix = "No inference traffic recorded yet; zero request/token counters are expected.`r`n`r`n" }
    return $prefix + (($wanted | Select-Object -Last 180) -join "`r`n")
}

function Get-DiagnosticsSnapshot {
    $health = Get-JsonEndpoint '/health'
    $slots = Get-JsonEndpoint '/slots'
    $metrics = Get-TextEndpoint '/metrics'
    $process = Get-CurrentProcessInfo
    $system = Get-SystemMemoryInfo
    $analysis = Get-LogAnalysis
    $healthStatus = [string](Get-SafeProperty $health 'status' 'offline')
    if ([string]::IsNullOrWhiteSpace($healthStatus)) { if ($health) { $healthStatus = 'responding' } else { $healthStatus = 'offline' } }

    $overview = New-Object Collections.Generic.List[string]
    $overview.Add("Health                  : $healthStatus")
    $overview.Add("Endpoint                : http://${HostAddress}:$Port")
    if ($Profile) { $overview.Add("Launcher profile        : $Profile") }
    if ($process) {
        $overview.Add("PID                     : $($process.Pid)")
        $overview.Add("Process working set     : $($process.WorkingSetMB) MB")
        $overview.Add("Process private memory  : $($process.PrivateMB) MB")
        if ($null -ne $process.GpuDedicatedMB) { $overview.Add("Process dedicated VRAM  : $($process.GpuDedicatedMB) MB") }
        if ($null -ne $process.GpuSharedMB) { $overview.Add("Process shared GPU RAM  : $($process.GpuSharedMB) MB") }
        $overview.Add("Process CPU time        : $($process.CpuSeconds) s")
        $overview.Add("Process threads         : $($process.Threads)")
    } else { $overview.Add('Process                 : not found from launcher PID file') }
    if ($system) {
        $overview.Add('')
        $overview.Add("System RAM used         : $($system.UsedMB) / $($system.TotalMB) MB")
        $overview.Add("System RAM available    : $($system.AvailableMB) MB")
        if ($null -ne $system.CommitMB) { $overview.Add("System commit           : $($system.CommitMB) / $($system.CommitLimitMB) MB") }
    }
    $overview.Add('')
    $overview.Add('SLOTS')
    $overview.Add((Get-SlotSummary $slots))

    $memory = New-Object Collections.Generic.List[string]
    $memory.Add('LIVE WINDOWS MEMORY')
    if ($process) {
        if ($null -ne $process.GpuDedicatedMB) { $memory.Add("  Dedicated VRAM (PID)   : $($process.GpuDedicatedMB) MB") } else { $memory.Add('  Dedicated VRAM (PID)   : not exposed by Windows counters') }
        if ($null -ne $process.GpuSharedMB) { $memory.Add("  Shared GPU RAM (PID)   : $($process.GpuSharedMB) MB") } else { $memory.Add('  Shared GPU RAM (PID)   : not exposed by Windows counters') }
        $memory.Add("  Working set            : $($process.WorkingSetMB) MB")
        $memory.Add("  Private memory         : $($process.PrivateMB) MB")
    }
    if ($system) {
        $memory.Add("  System RAM used        : $($system.UsedMB) / $($system.TotalMB) MB")
        if ($null -ne $system.CommitMB) { $memory.Add("  System commit          : $($system.CommitMB) / $($system.CommitLimitMB) MB") }
    }
    $memory.Add('')
    $memory.Add('LLAMA.CPP ALLOCATION FROM STARTUP LOG')
    $memory.Add($analysis.Summary)

    $slotsJson = 'No /slots response.'
    if ($null -ne $slots) { $slotsJson = $slots | ConvertTo-Json -Depth 20 }
    return [pscustomobject]@{
        Health = $healthStatus
        Overview = $overview -join "`r`n"
        Memory = $memory -join "`r`n"
        Performance = (Get-MetricsSummary $metrics) + "`r`n`r`nRECENT LLAMA.CPP LINES`r`n" + $analysis.Raw
        Command = Get-CommandText
        SlotsJson = $slotsJson
        Raw = $analysis.Raw
    }
}

function New-DiagnosticsForm {
    $surface = [Drawing.Color]::FromArgb(20,21,24)
    $panel = [Drawing.Color]::FromArgb(28,29,33)
    $text = [Drawing.Color]::FromArgb(242,243,245)
    $accent = [Drawing.Color]::FromArgb(88,184,255)
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Qwen Local Launcher - Runtime diagnostics'
    $form.Size = New-Object Drawing.Size(1120,820)
    $form.MinimumSize = New-Object Drawing.Size(900,680)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $surface
    $form.ForeColor = $text
    $form.Font = New-Object Drawing.Font('Segoe UI',9.5)
    $header = New-Object Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 86
    $header.BackColor = $panel
    $form.Controls.Add($header)
    $title = New-Object Windows.Forms.Label
    $title.Text = 'Runtime diagnostics'
    $title.AutoSize = $true
    $title.ForeColor = $text
    $title.Font = New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(22,13)
    $header.Controls.Add($title)
    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $true
    $status.ForeColor = $accent
    $status.Location = New-Object Drawing.Point(24,51)
    $header.Controls.Add($status)
    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs)
    $tabs.BringToFront()
    $boxes = @{}
    foreach ($name in @('Overview','Memory / offload','Performance','Command','Slots JSON','Raw llama.cpp')) {
        $tab = New-Object Windows.Forms.TabPage
        $tab.Text = $name
        $tab.BackColor = $surface
        $tab.ForeColor = $text
        $tab.Padding = New-Object Windows.Forms.Padding(16)
        [void]$tabs.TabPages.Add($tab)
        $box = New-Object Windows.Forms.TextBox
        $box.Multiline = $true
        $box.ReadOnly = $true
        $box.Dock = 'Fill'
        $box.ScrollBars = 'Both'
        $box.WordWrap = $false
        $box.BackColor = $surface
        $box.ForeColor = $text
        $box.BorderStyle = 'None'
        $box.Font = New-Object Drawing.Font('Consolas',10)
        $tab.Controls.Add($box)
        $boxes[$name] = $box
    }
    return [pscustomobject]@{ Form = $form; Status = $status; Boxes = $boxes }
}

try {
    if ($SelfTest) {
        $singleSlot = [pscustomobject]@{ id = 0; n_ctx = 160000; is_processing = $false }
        if ((Get-SlotSummary $singleSlot) -notmatch 'context=160000') { throw 'Single-slot self-test failed.' }
        $sample = @(
            'load_tensors: offloaded 64/65 layers to GPU',
            'load_tensors: Vulkan0 model buffer size = 12000.00 MiB',
            'load_tensors: CPU_Mapped model buffer size = 650.00 MiB',
            'llama_context: Vulkan_Host output buffer size = 4.00 MiB',
            'llama_kv_cache: Vulkan0 KV buffer size = 2048.00 MiB',
            'llama_context: Vulkan0 compute buffer size = 700.00 MiB',
            'llama_context: n_ctx = 160000',
            'llama_context: n_batch = 1024',
            'llama_context: n_ubatch = 128',
            "srv load_model: loaded multimodal model, 'mmproj-BF16.gguf'"
        )
        $parsed = Get-LogAnalysis -Lines $sample -SourceName 'self-test.log'
        foreach ($expected in @('64 / 65','2048','160000','1024','128')) {
            if ($parsed.Summary -notmatch [regex]::Escape($expected)) { throw "Diagnostics parser self-test failed for $expected." }
        }
        $ui = New-DiagnosticsForm
        $ui.Form.Dispose()
        Write-Host 'Runtime diagnostics self-test passed.'
        return
    }

    $ui = New-DiagnosticsForm
    $form = $ui.Form
    $status = $ui.Status
    $boxes = $ui.Boxes
    $refresh = [System.EventHandler]{
        try {
            $snapshot = Get-DiagnosticsSnapshot
            $status.Text = "Health: $($snapshot.Health)    Endpoint: http://${HostAddress}:$Port    Profile: $Profile"
            $boxes['Overview'].Text = $snapshot.Overview
            $boxes['Memory / offload'].Text = $snapshot.Memory
            $boxes['Performance'].Text = $snapshot.Performance
            $boxes['Command'].Text = $snapshot.Command
            $boxes['Slots JSON'].Text = $snapshot.SlotsJson
            $boxes['Raw llama.cpp'].Text = $snapshot.Raw
        } catch {
            Write-DiagnosticsError $_
            $status.Text = "Refresh error: $($_.Exception.Message) - see runtime-diagnostics-error.log"
        }
    }
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.add_Tick($refresh)
    $form.add_Shown({ $refresh.Invoke($null,[EventArgs]::Empty); $timer.Start() })
    $form.add_FormClosed({ $timer.Stop(); $timer.Dispose() })
    [void]$form.ShowDialog()
} catch {
    Write-DiagnosticsError $_
    if ($SelfTest) { throw }
    [Windows.Forms.MessageBox]::Show("Runtime diagnostics could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $script:ErrorLog",'Qwen Local Launcher - Diagnostics Error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}
