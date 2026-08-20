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

function Get-CurrentProcessInfo {
    if (-not (Test-Path -LiteralPath $script:PidPath -PathType Leaf)) { return $null }
    try {
        $serverPid = [int](Get-Content -LiteralPath $script:PidPath -Raw).Trim()
        $p = Get-Process -Id $serverPid -ErrorAction Stop
        $gpuDedicated = $null
        $gpuShared = $null
        try {
            [object[]]$rows = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction Stop | Where-Object { $_.Name -match "pid_${serverPid}_" })
            if ($rows.Length -gt 0) {
                $gpuDedicated = [math]::Round((($rows | Measure-Object DedicatedUsage -Sum).Sum) / 1MB, 1)
                $gpuShared = [math]::Round((($rows | Measure-Object SharedUsage -Sum).Sum) / 1MB, 1)
            }
        } catch {}
        return [pscustomobject]@{
            Pid = $p.Id
            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
            PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
            CpuSeconds = [math]::Round($p.CPU, 1)
            Threads = $p.Threads.Count
            GpuDedicatedMB = $gpuDedicated
            GpuSharedMB = $gpuShared
        }
    } catch { return $null }
}

function Get-SystemMemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalMB = [math]::Round([double]$os.TotalVisibleMemorySize / 1024, 0)
        $availableMB = [math]::Round([double]$os.FreePhysicalMemory / 1024, 0)
        $commitMB = $null
        $commitLimitMB = $null
        try {
            $perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
            $commitMB = [math]::Round([double]$perf.CommittedBytes / 1MB, 0)
            $commitLimitMB = [math]::Round([double]$perf.CommitLimit / 1MB, 0)
        } catch {}
        return [pscustomobject]@{
            TotalMB = $totalMB
            UsedMB = $totalMB - $availableMB
            AvailableMB = $availableMB
            CommitMB = $commitMB
            CommitLimitMB = $commitLimitMB
        }
    } catch { return $null }
}

function Get-LatestStderrLog {
    return Get-ChildItem -LiteralPath $script:LogDir -Filter '*.stderr.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-CommandText {
    $path = Join-Path $script:LogDir 'last-command.txt'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw).Trim() }
    return 'No command recorded yet.'
}

function Get-LogAnalysis {
    param([string[]]$Lines, [string]$SourceName = '')

    if ($null -eq $Lines) {
        $latest = Get-LatestStderrLog
        if (-not $latest) { return [pscustomobject]@{ Summary='No llama.cpp stderr log found yet.'; Raw='No llama.cpp stderr log found yet.' } }
        $SourceName = $latest.Name
        [string[]]$Lines = @(Get-Content -LiteralPath $latest.FullName -ErrorAction Stop)
    }

    $gpuModel = 0.0; $cpuModel = 0.0; $gpuKv = 0.0; $cpuKv = 0.0
    $gpuCompute = 0.0; $cpuCompute = 0.0; $gpuOutput = 0.0; $cpuOutput = 0.0
    $gpuLayers = $null; $totalLayers = $null; $context = $null
    $mmprojBackend = 'unknown'; $mmprojPath = $null; $mtpDetected = $false
    $cacheReuseDisabled = $false; $imageTokenWarning = $false
    $interesting = New-Object Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -match '(?i)(offload|buffer size|KV|compute|Vulkan|CUDA|ROCm|HIP|mmproj|mtmd|CLIP|vision|draft|MTP|speculat|n_ctx|cache_reuse|image tokens|prompt eval|eval time|tokens per second|flash)') { $interesting.Add($line) }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:-]+)\s+model buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $v=[double]$matches.size; if ($matches.device -match '(?i)CPU|Host') { $cpuModel += $v } else { $gpuModel += $v } }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:-]+)\s+KV buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $v=[double]$matches.size; if ($matches.device -match '(?i)CPU|Host') { $cpuKv += $v } else { $gpuKv += $v } }
        elseif ($line -match '(?i)KV buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $gpuKv += [double]$matches.size }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:-]+)\s+compute buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $v=[double]$matches.size; if ($matches.device -match '(?i)CPU|Host') { $cpuCompute += $v } else { $gpuCompute += $v } }
        elseif ($line -match '(?i)compute buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $gpuCompute += [double]$matches.size }
        if ($line -match '(?i)(?<device>[A-Za-z0-9_:-]+)\s+output buffer size\s*=\s*(?<size>[0-9.]+)\s*MiB') { $v=[double]$matches.size; if ($matches.device -match '(?i)CPU|Host') { $cpuOutput += $v } else { $gpuOutput += $v } }
        if ($line -match '(?i)offloaded\s+(?<gpu>\d+)\s*/\s*(?<total>\d+)\s+layers?\s+to\s+GPU') { $gpuLayers=[int]$matches.gpu; $totalLayers=[int]$matches.total }
        if ($line -match '(?i)n_ctx_slot\s*=\s*(?<ctx>\d+)') { $context=[int]$matches.ctx }
        if ($line -match '(?i)(CLIP|mtmd).*using\s+(?<backend>.+?)\s+backend') { $mmprojBackend=$matches.backend.Trim() }
        if ($line -match "(?i)loaded multimodal model,\s*'(?<path>[^']+)'" ) { $mmprojPath=$matches.path }
        if ($line -match '(?i)cache_reuse is not supported by multimodal') { $cacheReuseDisabled=$true }
        if ($line -match '(?i)require at minimum 1024 image tokens') { $imageTokenWarning=$true }
        if ($line -match '(?i)draft|MTP|speculat') { $mtpDetected=$true }
    }

    $command = Get-CommandText
    if ($mmprojBackend -eq 'unknown') {
        if ($command -match '--no-mmproj-offload') { $mmprojBackend = 'CPU (from --no-mmproj-offload)' }
        elseif ($gpuModel -gt 0 -and $mmprojPath) { $mmprojBackend = 'GPU likely; exact backend not logged' }
    }

    $summary = New-Object Collections.Generic.List[string]
    if ($SourceName) { $summary.Add("Source log                 : $SourceName") }
    $summary.Add(''); $summary.Add('MODEL / OFFLOAD')
    $summary.Add(('  GPU model buffers        : {0:N1} MiB' -f $gpuModel))
    $summary.Add(('  CPU model buffers        : {0:N1} MiB' -f $cpuModel))
    if ($null -ne $gpuLayers) { $summary.Add("  GPU layers               : $gpuLayers / $totalLayers") } else { $summary.Add('  GPU layers               : not found in current log') }
    $summary.Add(''); $summary.Add('KV / COMPUTE')
    $summary.Add(('  KV GPU                   : {0:N1} MiB' -f $gpuKv)); $summary.Add(('  KV CPU                   : {0:N1} MiB' -f $cpuKv))
    $summary.Add(('  Compute GPU              : {0:N1} MiB' -f $gpuCompute)); $summary.Add(('  Compute CPU              : {0:N1} MiB' -f $cpuCompute))
    $summary.Add(('  Output GPU               : {0:N1} MiB' -f $gpuOutput)); $summary.Add(('  Output CPU               : {0:N1} MiB' -f $cpuOutput))
    if ($null -ne $context) { $summary.Add("  Runtime context          : $context tokens") }
    $summary.Add(''); $summary.Add('MULTIMODAL / MTP')
    $summary.Add("  mmproj backend           : $mmprojBackend"); if ($mmprojPath) { $summary.Add("  mmproj file              : $mmprojPath") }
    $summary.Add("  MTP/speculative detected : $mtpDetected"); $summary.Add("  cache_reuse disabled     : $cacheReuseDisabled"); $summary.Add("  1024 image-token warning : $imageTokenWarning")

    return [pscustomobject]@{ Summary=$summary -join "`r`n"; Raw=if ($interesting.Count -gt 0) { ($interesting | Select-Object -Last 300) -join "`r`n" } else { 'No matching llama.cpp runtime lines yet.' } }
}

function Get-SlotSummary {
    param($SlotsResponse)
    [object[]]$slots = @()
    if ($null -ne $SlotsResponse) {
        if ($SlotsResponse -is [System.Array]) { [object[]]$slots = $SlotsResponse } else { [object[]]$slots = @($SlotsResponse) }
    }
    $lines = New-Object Collections.Generic.List[string]
    if ($slots.Length -eq 0) { $lines.Add('No slot data available.'); return $lines -join "`r`n" }
    foreach ($slot in $slots) {
        $id=Get-SafeProperty $slot 'id' '?'; $ctx=Get-SafeProperty $slot 'n_ctx' '?'; $processing=Get-SafeProperty $slot 'is_processing' $false
        $next=Get-SafeProperty $slot 'next_token' $null; $decoded=Get-SafeProperty $next 'n_decoded' '?'; $prompt=Get-SafeProperty $next 'n_prompt_tokens_processed' '?'
        $lines.Add("Slot $id : context=$ctx | processing=$processing | decoded=$decoded | prompt_processed=$prompt")
    }
    return $lines -join "`r`n"
}

function Get-MetricsSummary {
    param([string]$Metrics)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { return 'Metrics unavailable. Restart llama-server so --metrics is active.' }
    [string[]]$wanted = @($Metrics -split "`r?`n" | Where-Object { $_ -notmatch '^#' -and $_ -match '(?i)(tokens|prompt|predicted|requests|seconds|cache|draft|speculat|slots)' })
    if ($wanted.Length -eq 0) { return 'Metrics endpoint responded, but no selected counters matched.' }
    return ($wanted | Select-Object -Last 160) -join "`r`n"
}

function Get-DiagnosticsSnapshot {
    $health=Get-JsonEndpoint '/health'; $slotsResponse=Get-JsonEndpoint '/slots'; $metrics=Get-TextEndpoint '/metrics'; $proc=Get-CurrentProcessInfo; $system=Get-SystemMemoryInfo; $analysis=Get-LogAnalysis
    $healthStatus=[string](Get-SafeProperty $health 'status' 'offline'); if ([string]::IsNullOrWhiteSpace($healthStatus)) { $healthStatus=if ($health) {'responding'} else {'offline'} }
    $overview=New-Object Collections.Generic.List[string]; $overview.Add("Health                  : $healthStatus"); $overview.Add("Endpoint                : http://${HostAddress}:$Port"); if ($Profile) {$overview.Add("Launcher profile        : $Profile")}
    if ($proc) { $overview.Add("PID                     : $($proc.Pid)"); $overview.Add("Process working set     : $($proc.WorkingSetMB) MB"); $overview.Add("Process private memory  : $($proc.PrivateMB) MB"); if ($null -ne $proc.GpuDedicatedMB) {$overview.Add("Process dedicated VRAM  : $($proc.GpuDedicatedMB) MB")}; if ($null -ne $proc.GpuSharedMB) {$overview.Add("Process shared GPU RAM  : $($proc.GpuSharedMB) MB")}; $overview.Add("Process CPU time        : $($proc.CpuSeconds) s"); $overview.Add("Process threads         : $($proc.Threads)") } else {$overview.Add('Process                 : not found from launcher PID file')}
    if ($system) { $overview.Add(''); $overview.Add("System RAM used         : $($system.UsedMB) / $($system.TotalMB) MB"); $overview.Add("System RAM available    : $($system.AvailableMB) MB"); if ($null -ne $system.CommitMB) {$overview.Add("System commit           : $($system.CommitMB) / $($system.CommitLimitMB) MB")} }
    $overview.Add(''); $overview.Add('SLOTS'); $overview.Add((Get-SlotSummary $slotsResponse))
    $memory=New-Object Collections.Generic.List[string]; $memory.Add('LIVE WINDOWS MEMORY')
    if ($proc) { $memory.Add("  Dedicated VRAM (PID)   : $(if ($null -ne $proc.GpuDedicatedMB) { "$($proc.GpuDedicatedMB) MB" } else { 'not exposed by Windows counters' })"); $memory.Add("  Shared GPU RAM (PID)   : $(if ($null -ne $proc.GpuSharedMB) { "$($proc.GpuSharedMB) MB" } else { 'not exposed by Windows counters' })"); $memory.Add("  Working set            : $($proc.WorkingSetMB) MB"); $memory.Add("  Private memory         : $($proc.PrivateMB) MB") }
    if ($system) { $memory.Add("  System RAM used        : $($system.UsedMB) / $($system.TotalMB) MB"); if ($null -ne $system.CommitMB) {$memory.Add("  System commit          : $($system.CommitMB) / $($system.CommitLimitMB) MB")} }
    $memory.Add(''); $memory.Add('LLAMA.CPP ALLOCATION FROM STARTUP LOG'); $memory.Add($analysis.Summary)
    $slotsJson='No /slots response.'; if ($null -ne $slotsResponse) {$slotsJson=$slotsResponse | ConvertTo-Json -Depth 20}
    return [pscustomobject]@{ Health=$healthStatus; Overview=$overview -join "`r`n"; Memory=$memory -join "`r`n"; Performance=(Get-MetricsSummary $metrics)+"`r`n`r`nRECENT TIMING / SPECULATIVE LINES`r`n"+(($analysis.Raw -split "`r?`n" | Where-Object {$_ -match '(?i)prompt eval|eval time|tokens per second|draft|speculat|slot'} | Select-Object -Last 140)-join "`r`n"); Command=Get-CommandText; SlotsJson=$slotsJson; Raw=$analysis.Raw }
}

function New-DiagnosticsForm {
    $surface=[Drawing.Color]::FromArgb(20,21,24); $panel=[Drawing.Color]::FromArgb(28,29,33); $text=[Drawing.Color]::FromArgb(242,243,245); $accent=[Drawing.Color]::FromArgb(88,184,255)
    $form=New-Object Windows.Forms.Form; $form.Text='Qwen Local Launcher - Runtime diagnostics'; $form.Size=New-Object Drawing.Size(1120,820); $form.MinimumSize=New-Object Drawing.Size(900,680); $form.StartPosition='CenterScreen'; $form.BackColor=$surface; $form.ForeColor=$text; $form.Font=New-Object Drawing.Font('Segoe UI',9.5)
    $header=New-Object Windows.Forms.Panel; $header.Dock='Top'; $header.Height=86; $header.BackColor=$panel; $form.Controls.Add($header)
    $title=New-Object Windows.Forms.Label; $title.Text='Runtime diagnostics'; $title.AutoSize=$true; $title.ForeColor=$text; $title.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold); $title.Location=New-Object Drawing.Point(22,13); $header.Controls.Add($title)
    $status=New-Object Windows.Forms.Label; $status.AutoSize=$true; $status.ForeColor=$accent; $status.Location=New-Object Drawing.Point(24,51); $header.Controls.Add($status)
    $tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'; $form.Controls.Add($tabs); $tabs.BringToFront(); $boxes=@{}
    foreach ($name in @('Overview','Memory / offload','Performance','Command','Slots JSON','Raw llama.cpp')) { $tab=New-Object Windows.Forms.TabPage; $tab.Text=$name; $tab.BackColor=$surface; $tab.ForeColor=$text; $tab.Padding=New-Object Windows.Forms.Padding(16); [void]$tabs.TabPages.Add($tab); $box=New-Object Windows.Forms.TextBox; $box.Multiline=$true; $box.ReadOnly=$true; $box.Dock='Fill'; $box.ScrollBars='Both'; $box.WordWrap=$false; $box.BackColor=$surface; $box.ForeColor=$text; $box.BorderStyle='None'; $box.Font=New-Object Drawing.Font('Consolas',10); $tab.Controls.Add($box); $boxes[$name]=$box }
    return [pscustomobject]@{Form=$form;Status=$status;Boxes=$boxes}
}

try {
    if ($SelfTest) {
        $singleSlot=[pscustomobject]@{id=0;n_ctx=160000;is_processing=$false}; $slotText=Get-SlotSummary $singleSlot; if ($slotText -notmatch 'context=160000') {throw 'Single-slot normalization self-test failed.'}
        $sample=@('llama_model_loader: Vulkan0 model buffer size = 12000.0 MiB','llama_kv_cache: Vulkan0 KV buffer size = 2048.0 MiB','llama_context: Vulkan0 compute buffer size = 700.0 MiB','load_tensors: offloaded 64/65 layers to GPU','clip_ctx: CLIP using CPU backend',"srv load_model: loaded multimodal model, 'mmproj-BF16.gguf'",'srv load_model: initializing, n_slots = 1, n_ctx_slot = 160000, kv_unified = false')
        $parsed=Get-LogAnalysis -Lines $sample -SourceName 'self-test.log'; if ($parsed.Summary -notmatch '64 / 65' -or $parsed.Summary -notmatch '2048' -or $parsed.Summary -notmatch 'CPU backend') {throw 'Diagnostics parser self-test failed.'}
        $ui=New-DiagnosticsForm; $ui.Form.Dispose(); Write-Host 'Runtime diagnostics self-test passed.'; return
    }
    $ui=New-DiagnosticsForm; $form=$ui.Form; $status=$ui.Status; $boxes=$ui.Boxes
    $refresh=[System.EventHandler]{ try { $snapshot=Get-DiagnosticsSnapshot; $status.Text="Health: $($snapshot.Health)    Endpoint: http://${HostAddress}:$Port    Profile: $Profile"; $boxes['Overview'].Text=$snapshot.Overview; $boxes['Memory / offload'].Text=$snapshot.Memory; $boxes['Performance'].Text=$snapshot.Performance; $boxes['Command'].Text=$snapshot.Command; $boxes['Slots JSON'].Text=$snapshot.SlotsJson; $boxes['Raw llama.cpp'].Text=$snapshot.Raw } catch { Write-DiagnosticsError $_; $status.Text="Refresh error: $($_.Exception.Message) - see runtime-diagnostics-error.log" } }
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=2000; $timer.add_Tick($refresh); $form.add_Shown({$refresh.Invoke($null,[EventArgs]::Empty);$timer.Start()}); $form.add_FormClosed({$timer.Stop();$timer.Dispose()}); [void]$form.ShowDialog()
} catch { Write-DiagnosticsError $_; if ($SelfTest) {throw}; [Windows.Forms.MessageBox]::Show("Runtime diagnostics could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $script:ErrorLog",'Qwen Local Launcher - Diagnostics Error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
