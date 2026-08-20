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

if (-not ('QwenServerJob' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.dll') -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class QwenServerJob
{
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private static IntPtr job = IntPtr.Zero;
    private static int attachedPid = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int infoType, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static void EnsureJob()
    {
        if (job != IntPtr.Zero) return;
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr ptr = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(job, 9, ptr, (uint)length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed");
        }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    public static bool Attach(Process process)
    {
        if (process == null || process.HasExited) return false;
        if (attachedPid == process.Id && job != IntPtr.Zero) return true;
        EnsureJob();
        if (!AssignProcessToJobObject(job, process.Handle))
        {
            int error = Marshal.GetLastWin32Error();
            if (error != 5) throw new Win32Exception(error, "AssignProcessToJobObject failed");
            return false;
        }
        attachedPid = process.Id;
        return true;
    }

    public static int AttachedPid { get { return attachedPid; } }

    public static void KillAll()
    {
        if (job != IntPtr.Zero)
        {
            CloseHandle(job);
            job = IntPtr.Zero;
        }
        attachedPid = 0;
    }
}
"@
}

function Start-QwenDiagnosticsEncoded {
    $diag = Join-Path $script:Root 'scripts\runtime-diagnostics.ps1'
    $escape = {
        param([string]$Value)
        return $Value.Replace("'", "''")
    }
    $diagEsc = & $escape $diag
    $rootEsc = & $escape $script:Root
    $hostEsc = & $escape ([string]$script:Config.Host)
    $profileEsc = & $escape ([string]$script:CurrentProfile)
    $command = "& '$diagEsc' -Root '$rootEsc' -HostAddress '$hostEsc' -Port $([int]$script:Config.Port) -Profile '$profileEsc'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $process.Dispose()
}

function Register-QwenPopupBehaviorGuards {
    $script:QwenInteractionGuardsInstalled = $false

    $installHandler = [System.EventHandler]{
        if ($script:QwenInteractionGuardsInstalled) { return }

        $popupVar = Get-Variable -Name Popup -Scope Script -ErrorAction SilentlyContinue
        $stopVar = Get-Variable -Name StopButton -Scope Script -ErrorAction SilentlyContinue
        $restartVar = Get-Variable -Name RestartButton -Scope Script -ErrorAction SilentlyContinue
        $quitVar = Get-Variable -Name QuitButton -Scope Script -ErrorAction SilentlyContinue
        $timerVar = Get-Variable -Name Timer -Scope Script -ErrorAction SilentlyContinue
        if (-not $popupVar -or -not $stopVar -or -not $restartVar -or -not $quitVar -or -not $timerVar) { return }

        $script:QwenInteractionGuardsInstalled = $true
        $script:QwenExpectedServerStop = $false
        $script:QwenExpectedServerRestart = $false

        function script:Open-RuntimeDiagnostics {
            try { Start-QwenDiagnosticsEncoded }
            catch { try { Write-TrayRuntimeError $_ } catch {} }
        }

        $stopVar.Value.add_MouseDown({
            $script:QwenExpectedServerStop = $true
            try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
        })
        $stopVar.Value.add_Click({
            try {
                if ($script:Process -and -not $script:Process.HasExited) {
                    try { [QwenServerJob]::KillAll() } catch { Write-TrayRuntimeError $_ }
                    try { $script:Process.WaitForExit(3000) | Out-Null } catch {}
                }
                if (-not $script:Process -or $script:Process.HasExited) {
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

        $quitVar.Value.add_MouseDown({
            try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
        })
        $quitVar.Value.add_Click({
            try {
                if ($script:Process -and -not $script:Process.HasExited) {
                    [QwenServerJob]::KillAll()
                    try { $script:Process.WaitForExit(3000) | Out-Null } catch {}
                }
                if ($script:Process -and $script:Process.HasExited) {
                    $script:Process = $null
                    Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
                    Exit-Launcher
                }
            } catch { try { Write-TrayRuntimeError $_ } catch {} }
        })

        $script:QwenPopupGuardTimer = New-Object System.Windows.Forms.Timer
        $script:QwenPopupGuardTimer.Interval = 100
        $script:QwenPopupGuardTimer.add_Tick({
            try {
                if ($script:Process -and -not $script:Process.HasExited -and [QwenServerJob]::AttachedPid -ne $script:Process.Id) {
                    try { [void][QwenServerJob]::Attach($script:Process) } catch { Write-TrayRuntimeError $_ }
                }

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
