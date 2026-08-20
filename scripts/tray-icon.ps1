#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:QwenRuntimeOverridesInstalled = $false
$script:QwenLastSummaryKey = $null

function New-QwenBrandIcon {
    param([Parameter(Mandatory)][string]$IconPath)
    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) { throw "Tray icon not found: $IconPath" }
    $stream = [IO.File]::OpenRead($IconPath)
    try { $temporary = New-Object System.Drawing.Icon($stream,32,32); try { return $temporary.Clone() } finally { $temporary.Dispose() } } finally { $stream.Dispose() }
}

function Update-QwenRuntimeSummary {
    try {
        $root=Split-Path -Parent $PSScriptRoot; $logDir=Join-Path $root 'logs'
        $latest=Get-ChildItem -LiteralPath $logDir -Filter '*.stderr.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) {return}
        $key="$($latest.FullName)|$($latest.Length)|$($latest.LastWriteTimeUtc.Ticks)";if ($script:QwenLastSummaryKey -eq $key) {return}
        $commandPath=Join-Path $logDir 'last-command.txt'; $command=if(Test-Path -LiteralPath $commandPath){((Get-Content -LiteralPath $commandPath -Raw).Trim()}else{'No command recorded.'}
        [string[]]$important=@(Select-String -LiteralPath $latest.FullName -Pattern '(?i)offload|buffer size|KV|compute|Vulkan|CUDA|ROCm|HIP|mmproj|mtmd|CLIP|vision|draft|MTP|speculat|n_ctx|cache_reuse|image tokens|prompt eval|eval time|tokens per second|flash' -ErrorAction SilentlyContinue | Select-Object -Last 320 | ForEach-Object {$_.Line})
        $lines=New-Object Collections.Generic.List[string]; $lines.Add("Generated: $(Get-Date -Format o)"); $lines.Add("Source log: $($latest.Name)"); $lines.Add(''); $lines.Add('COMMAND'); $lines.Add($command); $lines.Add(''); $lines.Add('KEY LLAMA.CPP RUNTIME LINES'); if($important.Length -gt 0){foreach($line in $important){$lines.Add($line)}}else{$lines.Add('No matching runtime lines yet.')}
        $lines -join "`r`n" | Set-Content -LiteralPath (Join-Path $logDir 'latest-runtime-summary.txt') -Encoding UTF8; $script:QwenLastSummaryKey=$key
    } catch { try {Write-TrayRuntimeError $_} catch {} }
}

function Install-QwenRuntimeOverrides {
    if ($script:QwenRuntimeOverridesInstalled) {return}
    $timerVar=Get-Variable -Name Timer -Scope Script -ErrorAction SilentlyContinue; $processVar=Get-Variable -Name Process -Scope Script -ErrorAction SilentlyContinue
    if (-not $timerVar -or -not $processVar) {return}
    $script:QwenRuntimeOverridesInstalled=$true

    function script:Stop-QwenServer {
        param([switch]$ForRestart)
        $script:Stopping=$true; $success=$true
        try {
            if(-not $script:Process){[void](Connect-ExistingQwenServer)}
            if($script:Process){
                try{$script:Process.Refresh()}catch{}
                if(-not $script:Process.HasExited){
                    $rootPid=$script:Process.Id
                    try{[int[]]$treeIds=@(Get-ProcessTreeIds -RootPid $rootPid)}catch{Write-TrayRuntimeError $_;[int[]]$treeIds=@($rootPid)}
                    if(Test-AnyProcessAlive $treeIds){$graceful=Invoke-TaskKillSafe -ProcessId $rootPid -Tree;if($graceful.ExitCode -ne 0 -and $graceful.StdErr){Add-Content -LiteralPath (Join-Path $script:LogDir 'tray-runtime-error.log') -Value "[$(Get-Date -Format o)] Graceful taskkill returned $($graceful.ExitCode): $($graceful.StdErr)" -Encoding UTF8};$deadline=(Get-Date).AddSeconds([int]$script:Config.StopTimeoutSeconds);while((Get-Date)-lt $deadline -and (Test-AnyProcessAlive $treeIds)){Start-Sleep -Milliseconds 200}}
                    if(Test-AnyProcessAlive $treeIds){if('QwenServerJob' -as [type]){try{[QwenServerJob]::KillAll()}catch{Write-TrayRuntimeError $_}};$deadline=(Get-Date).AddSeconds(3);while((Get-Date)-lt $deadline -and (Test-AnyProcessAlive $treeIds)){Start-Sleep -Milliseconds 100}}
                    if(Test-AnyProcessAlive $treeIds){for($i=$treeIds.Length-1;$i-ge 0;$i--){$pidToStop=[int]$treeIds[$i];try{Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue}catch{}};$deadline=(Get-Date).AddSeconds(3);while((Get-Date)-lt $deadline -and (Test-AnyProcessAlive $treeIds)){Start-Sleep -Milliseconds 100}}
                    if(Test-AnyProcessAlive $treeIds){for($i=$treeIds.Length-1;$i-ge 0;$i--){$pidToStop=[int]$treeIds[$i];if(Get-Process -Id $pidToStop -ErrorAction SilentlyContinue){[void](Invoke-TaskKillSafe -ProcessId $pidToStop -Tree -Force)}};$deadline=(Get-Date).AddSeconds(3);while((Get-Date)-lt $deadline -and (Test-AnyProcessAlive $treeIds)){Start-Sleep -Milliseconds 100}}
                    if(Test-AnyProcessAlive $treeIds){[int[]]$survivors=@($treeIds|Where-Object{Get-Process -Id $_ -ErrorAction SilentlyContinue});throw "Could not stop the full llama.cpp process tree. Surviving PID(s): $($survivors -join ', ')" }
                }
            }
        } catch {$success=$false;Write-TrayRuntimeError $_;try{Set-LauncherState 'Error' 'stop failed; see logs'}catch{};try{$script:NotifyIcon.ShowBalloonTip(5000,'Could not stop llama.cpp',$_.Exception.Message,[Windows.Forms.ToolTipIcon]::Error)}catch{}}
        finally{if($success){Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue;$script:Process=$null;$script:StartupDeadline=$null;if(-not $ForRestart){Set-LauncherState 'Stopped' $null}};$script:Stopping=$false}
        return $success
    }

    $script:Timer.add_Tick({if($script:State -in @('Starting','Running')){Update-QwenRuntimeSummary}})
}

function Register-QwenTrayIcon {
    param([Parameter(Mandatory)][string]$IconPath)
    $script:QwenTrayIconPath=$IconPath; $script:QwenBrandIcon=$null
    $iconHandler=[System.EventHandler]{
        $notifyVar=Get-Variable -Name NotifyIcon -Scope Script -ErrorAction SilentlyContinue
        if($notifyVar -and $notifyVar.Value -is [System.Windows.Forms.NotifyIcon]){$notify=$notifyVar.Value;if(-not $script:QwenBrandIcon){$script:QwenBrandIcon=New-QwenBrandIcon -IconPath $script:QwenTrayIconPath};if(-not [object]::ReferenceEquals($notify.Icon,$script:QwenBrandIcon)){$notify.Icon=$script:QwenBrandIcon}}
        Install-QwenRuntimeOverrides
    }
    [System.Windows.Forms.Application]::add_Idle($iconHandler)
}
