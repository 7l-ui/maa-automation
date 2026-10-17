<#
refresh-maa.ps1 -- keep the resident MAA (and its emulator) healthy.

Registered as the scheduled task "MAA-Refresh" (elevated). It does three jobs,
depending on why it was called:

  1. pre-run refresh (00:25-00:40 / 08:25-08:40): restart MAA so that it re-checks
     the program version, the hot-update data and the resource/activity data right
     before the 01:00 / 09:00 runs.
  2. stall recovery (any time): if an MAA task is in progress but the log has been
     silent for more than StallMinutes, that task is wedged (a frozen emulator is
     the usual cause) -- kill the wedged emulator and restart MAA so the next run
     boots a fresh instance.
  3. otherwise: nothing (MAA simply idles between runs).

Why it must run elevated (RunLevel=Highest): MAA runs as administrator, and after
an automatic update it is restarted by MAA.Updater.exe, i.e. OUTSIDE the
MAA-Autostart task -- Stop-ScheduledTask no longer reaches it, and a normal
Stop-Process fails with "Access is denied". An elevated script can kill it, and it
can also kill a wedged LDPlayer instance, which is likewise elevated.

ASCII only on purpose: Windows PowerShell 5.1 reads BOM-less .ps1 files using the
system ANSI codepage (GBK here), which would mangle any non-ASCII source.
#>
[CmdletBinding()]
param(
    [string]$TaskName        = 'MAA-Autostart',
    [string]$LogFile         = 'C:\MAA\scripts\maa-hooks.log',
    [string]$MaaLog          = 'C:\MAA\debug\gui.log',
    [string]$ConfigPath      = 'C:\MAA\config\gui.new.json',
    [string]$AsstLog         = 'C:\MAA\debug\asst.log',
    [string]$EmulatorDir     = 'C:\leidian\LDPlayer9',
    [string]$Serial          = 'emulator-5554',
    [string[]]$PreRunWindows = @('00:25-00:40', '08:25-08:40'),
    [int]$StallMinutes       = 10,
    [int]$WaitSeconds        = 60,
    [string]$ResourceDir     = 'C:\MAA\resource',
    [string]$ResourceVersionUrl = 'https://raw.githubusercontent.com/MaaAssistantArknights/MaaResource/main/resource/version.json',
    [string]$ResourceZipUrl  = 'https://codeload.github.com/MaaAssistantArknights/MaaResource/zip/refs/heads/main',
    [int]$ResourceTimeoutSeconds = 600,
    [switch]$SkipResourceUpdate,
    [switch]$Force
)

function Write-Log([string]$Message) {
    $line = '{0} [refresh-maa] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.UTF8Encoding]::new($false)) } catch { }
    Write-Output $line
}

# Run an external program, giving up after $TimeoutSeconds. adb can hang forever
# when the guest Android is wedged, which is exactly what we are detecting here.
function Invoke-WithTimeout {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 15)
    $tmpOut = Join-Path $env:TEMP ('maa-refresh-{0}.out' -f (Get-Random))
    $tmpErr = "$tmpOut.err"
    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    $finished = $false
    try { Wait-Process -Id $proc.Id -Timeout $TimeoutSeconds -ErrorAction Stop; $finished = $true } catch { }
    if (-not $finished) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
        return @{ TimedOut = $true; Output = '' }
    }
    $out = ''
    if (Test-Path -LiteralPath $tmpOut) { $out = (Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue) }
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    return @{ TimedOut = $false; Output = $out }
}

# Is MAA in the middle of a task chain? (a "start" without a matching stop)
# A "GUI started" line resets the flag: after a restart the process is brand new,
# so an unmatched start from before the restart must not count -- otherwise a
# recovered stall would look "still running" forever and the watchdog would restart
# MAA over and over all night.
# Deliberately ASCII-only anchors: this file must stay pure ASCII, because
# PowerShell 5.1 reads BOM-less .ps1 files as the ANSI codepage (GBK here) and
# would mangle any Chinese literal, silently breaking the match.
function Test-MaaTaskInProgress {
    param([string]$Path, [int]$Tail = 400)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $running = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Tail)) {
        if ($line -match 'GUI started|Idle: false to true') { $running = $false }
        elseif ($line -match 'Start Task Chain:') { $running = $true }
        elseif ($line -match 'Completed Task Chain:|Post actions:') { $running = $false }
    }
    return $running
}

function Get-MaaLogIdleMinutes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [double]::MaxValue }
    # Ignore MAA's own "[WRN] ... stalled ..." heartbeat: it repeats every ~30 min
    # while a task is wedged and would otherwise mask the stall.
    $last = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 200 |
        Where-Object { $_ -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})' -and $_ -notmatch '\[WRN\]' } |
        Select-Object -Last 1
    if ($last -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        $stamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        return ((Get-Date) - $stamp).TotalMinutes
    }
    return [double]::MaxValue
}

function Test-InPreRunWindow {
    param([string[]]$Windows)
    $nowSpan = [TimeSpan]::Parse((Get-Date).ToString('HH:mm'))
    foreach ($w in $Windows) {
        $parts = $w.Split('-')
        if ($parts.Count -ne 2) { continue }
        $from = [TimeSpan]::Parse($parts[0].Trim())
        $to = [TimeSpan]::Parse($parts[1].Trim())
        if ($nowSpan -ge $from -and $nowSpan -le $to) { return $true }
    }
    return $false
}

function Test-EmulatorHealthy {
    param([string]$AdbPath, [string]$Device, [int]$TimeoutSeconds = 15)
    if (-not (Test-Path -LiteralPath $AdbPath)) { return $true }   # cannot tell -> do not touch it
    $r = Invoke-WithTimeout -FilePath $AdbPath -Arguments @('-s', $Device, 'shell', 'getprop', 'sys.boot_completed') -TimeoutSeconds $TimeoutSeconds
    if ($r.TimedOut) { return $false }
    return ($r.Output -match '1')
}

function Stop-WedgedEmulator {
    param([string]$Dir)
    $console = Join-Path $Dir 'ldconsole.exe'
    if (Test-Path -LiteralPath $console) {
        Write-Log 'asking the LDPlayer console to quit instance 0'
        $null = Invoke-WithTimeout -FilePath $console -Arguments @('quit', '--index', '0') -TimeoutSeconds 20
    }
    Start-Sleep -Seconds 5
    foreach ($name in @('dnplayer', 'Ld9BoxHeadless', 'Ld9BoxSVC')) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Log ("killed {0} (PID {1})" -f $name, $p.Id) }
            catch { Write-Log ("could not kill {0} (PID {1}): {2}" -f $name, $p.Id, $_.Exception.Message) }
        }
    }
}

# MAA only *notices* resource updates by itself: it pops up a "resource update
# found, please update manually under Settings - Update Settings - Resource Update"
# notice and otherwise waits for a MirrorChyan CDK. So we fetch MaaResource
# ourselves -- the very same zip MAA uses. Fresh resources are what carry the
# templates for new activity popups / stages, i.e. exactly what breaks recognition
# after a game update.
function Update-MaaResource {
    param([string]$Dir, [string]$VersionUrl, [string]$ZipUrl, [int]$TimeoutSeconds = 600)

    $localVersion = $null
    $localVersionFile = Join-Path $Dir 'version.json'
    if (Test-Path -LiteralPath $localVersionFile) {
        try { $localVersion = (Get-Content -LiteralPath $localVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json).last_updated } catch { }
    }

    $remoteVersion = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-WebRequest -Uri $VersionUrl -UseBasicParsing -Headers @{ 'User-Agent' = 'MAA-Refresh' } -TimeoutSec 60
        $remoteVersion = ($resp.Content | ConvertFrom-Json).last_updated
    }
    catch {
        Write-Log ('resource version check failed: {0}' -f $_.Exception.Message)
        return
    }

    Write-Log ("resource version: local='{0}' remote='{1}'" -f $localVersion, $remoteVersion)
    if (-not $remoteVersion) { return }
    # Both are zero-padded "yyyy-MM-dd HH:mm:ss.fff", so an ordinal compare is exact.
    if ($localVersion -and [string]::CompareOrdinal($remoteVersion, $localVersion) -le 0) {
        Write-Log 'resources are up to date.'
        return
    }

    $zip = Join-Path $env:TEMP 'MaaResource.zip'
    $dest = Join-Path $env:TEMP ('MaaResource-extract-{0}' -f (Get-Random))
    try {
        Write-Log ('downloading new resources from {0}' -f $ZipUrl)
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec $TimeoutSeconds
        Write-Log ('downloaded {0:N1} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)

        $inner = Get-ChildItem -LiteralPath $dest -Directory | Select-Object -First 1
        $src = Join-Path $inner.FullName 'resource'
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Log 'unexpected zip layout (no resource/ inside); aborting without touching the install.'
            return
        }

        Write-Log ('applying {0} over {1} (merge, MAA is stopped)' -f $src, $Dir)
        Copy-Item -Path (Join-Path $src '*') -Destination $Dir -Recurse -Force
        Write-Log ('resources updated: {0} -> {1}' -f $localVersion, $remoteVersion)
    }
    catch {
        Write-Log ('resource update failed: {0}' -f $_.Exception.Message)
    }
    finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-MaaRunning {
    return [bool](Get-Process -Name 'MAA' -ErrorAction SilentlyContinue)
}

# "Running" is not enough: on 2026-10-12 08:40 MAA started and died two seconds
# later (exit code 0xC0000005), which the old check happily accepted. A healthy
# start writes these lines, so require one of them to be recent.
function Test-MaaHealthy {
    param([string]$Path, [int]$WithinSeconds = 60)
    if (-not (Test-MaaRunning)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $last = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 60 |
        Where-Object { $_ -match 'Timer wait time|Init: false to true' } | Select-Object -Last 1
    if (-not $last) { return $false }
    if ($last -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        $stamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        return (((Get-Date) - $stamp).TotalSeconds -le $WithinSeconds)
    }
    return $false
}

# Start a run on demand by sending MAA's global LinkStart hotkey. This is the only
# way to kick a run off without editing MAA's config (which needs MAA stopped), and
# it works from this elevated context.
function Start-MaaRunNow {
    param([string]$Path)
    if (-not (Test-MaaRunning)) { Write-Log 'cannot start a run: MAA is not running.'; return $false }
    # LinkStart is a TOGGLE: pressing it while a run is going STOPS that run
    # (measured 2026-10-12 17:30:08: MAA logged its stop). Only press it when idle.
    if (Test-MaaTaskInProgress -Path $Path) { Write-Log 'a run is already in progress; NOT pressing the hotkey (it would stop the run).'; return $false }
    $before = @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 200 | Where-Object { $_ -match 'Start Task Chain:' }).Count
    Write-Log 'sending the LinkStart hotkey (Ctrl+Shift+Alt+L)'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait('^+%l')
    }
    catch {
        Write-Log ('could not send the hotkey: {0}' -f $_.Exception.Message)
        return $false
    }
    # Cold-booting the emulator takes 45-60 s, so allow a generous window.
    Start-Sleep -Seconds 75
    $after = @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 200 | Where-Object { $_ -match 'Start Task Chain:' }).Count
    if ($after -gt $before) { Write-Log 'a new run has started.'; return $true }
    Write-Log 'no new run detected after the hotkey; falling back to RunDirectly.'
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 5
    if (Test-MaaRunning) {
        try { Stop-Process -Name 'MAA' -Force -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 5
    }
    if (Set-MaaRunDirectly -Path $ConfigPath -Value $true) {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 60
        if (Test-MaaTaskInProgress -Path $Path) { Write-Log 'a run has started via RunDirectly.'; return $true }
    }
    Write-Log 'could not start a run automatically.'
    return $false
}

# Verdict on the most recent scheduled run: has it ended, and did it end with errors?
function Get-LastRunVerdict {
    param([string]$Path, [int]$Tail = 1500)
    $res = @{ Key = $null; Errors = 0; Finished = $false; RetryWorth = $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Tail
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'Start Task Chain: StartUp') { $idx = $i } }
    if ($idx -lt 0) { return $res }
    $after = $lines[$idx..($lines.Count - 1)]
    if ($lines[$idx] -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { $res.Key = $Matches[1] }
    else { $res.Key = $lines[$idx].Trim() }
    $res.Errors = @($after | Where-Object { $_ -match '\[ERR\]\[TaskQueueViewModel\]' }).Count
    $res.Finished = (@($after | Where-Object { $_ -match 'Post actions:' }).Count -gt 0)
    $idleMin = Get-MaaLogIdleMinutes -Path $Path
    if (-not $res.Finished -and $res.Errors -gt 0 -and $idleMin -gt 5) { $res.Finished = $true }
    $res.RetryWorth = ($res.Errors -gt 0 -and $res.Finished)
    return $res
}

# When the game itself freezes (the usual cause is the emulator being paged out
# under memory pressure) ADB keeps answering and MAA keeps taking screenshots, so
# nothing above fires -- but the screen never advances, and MAA burns through its
# recognition retries instead. asst.log carries "cur_retry":N climbing towards
# retry_times (20), which is the earliest reliable sign. Measured on 2026-10-12:
# the game sat on the 1-7 loading screen unchanged for 58 s (two failure shots with
# identical sha256) while asst.log showed cur_retry climbing 14 -> 20.
function Test-MaaStuckRetrying {
    param([string]$Path, [int]$Threshold = 18, [int]$Tail = 120)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $max = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Tail)) {
        foreach ($m in [regex]::Matches($line, '"cur_retry":(\d+)')) {
            $v = [int]$m.Groups[1].Value
            if ($v -gt $max) { $max = $v }
        }
    }
    return ($max -ge $Threshold)
}

# The emulator can also die outright (its VM processes disappear) while MAA keeps
# retrying against a dead ADB target. That is the cheapest thing to detect: the VM
# processes are simply gone. Measured 2026-10-12 17:58: Ld9BoxHeadless + dnplayer
# vanished mid-run, only the Ld9BoxSVC service was left, and MAA hung on Infrast.
function Test-EmulatorPresent {
    return [bool](Get-Process -Name 'dnplayer', 'Ld9BoxHeadless' -ErrorAction SilentlyContinue)
}
# High retry counts alone are NOT proof of a freeze: the reception room in the
# Infrast task legitimately retries a lot (measured 2026-10-12 18:16: cur_retry hit
# 20 while the room was being processed normally). The real signature, taken from
# MAA's own failure shots on 10/12, is that the screen does not change at all --
# two screencaps a few seconds apart with identical SHA256.
function Test-ScreenFrozen {
    param([string]$AdbPath, [string]$Device, [int]$WaitSeconds = 8)
    if (-not (Test-Path -LiteralPath $AdbPath)) { return $false }
    $hashes = @()
    for ($i = 0; $i -lt 2; $i++) {
        $remote = '/sdcard/watchdog.png'
        $r = Invoke-WithTimeout -FilePath $AdbPath -Arguments @('-s', $Device, 'shell', 'screencap', '-p', $remote) -TimeoutSeconds 20
        if ($r.TimedOut) { return $false }
        $local = Join-Path $env:TEMP ('watchdog-{0}.png' -f (Get-Random))
        $r2 = Invoke-WithTimeout -FilePath $AdbPath -Arguments @('-s', $Device, 'pull', $remote, $local) -TimeoutSeconds 20
        if ($r2.TimedOut -or -not (Test-Path -LiteralPath $local)) { return $false }
        $hashes += (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
        if ($i -eq 0) { Start-Sleep -Seconds $WaitSeconds }
    }
    return ($hashes.Count -eq 2 -and $hashes[0] -eq $hashes[1])
}
# RunDirectly makes MAA run the task chain the moment it launches. That is a far
# more reliable way to kick off a run than the global hotkey: on 2026-10-12 18:56
# the hotkey was sent right after a restart and simply did nothing, losing the whole
# retry. The pre-run refresh resets it to false so normal timer behaviour returns.
function Set-MaaRunDirectly {
    param([string]$Path, [bool]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg.Configurations.Default.Gui.StartUpSettings.RunDirectly = $Value
        [IO.File]::WriteAllText($Path, ($cfg | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        return $true
    }
    catch {
        Write-Log ('could not set RunDirectly: {0}' -f $_.Exception.Message)
        return $false
    }
}
# The decisive stall signal is TASK-level progress: a healthy run keeps printing
# (task-level progress markers: the Chinese task/facility log lines)
# for 8 hours because the core log kept flowing and the game screen kept animating
# (so neither the "both logs silent" nor the screenshot test fired).
function Get-MaaProgressIdleMinutes {
    param([string]$Path, [int]$Tail = 400)
    if (-not (Test-Path -LiteralPath $Path)) { return [double]::MaxValue }
    $last = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Tail |
        Where-Object { $_ -match 'Start Task Chain:|Completed Task Chain:|Post actions:' } |
        Select-Object -Last 1
    if ($last -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        $stamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        return ((Get-Date) - $stamp).TotalMinutes
    }
    return [double]::MaxValue
}
# ---------------------------------------------------------------- main --------

$elevated   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Keep our own cadence at 10 minutes (idempotent, needs elevation). Without it this
# task only ran at 00:30 / 08:30, so it could never catch a stall that happens in
# the middle of a run -- which is exactly what happened on 2026-10-01 01:03.
if ($elevated) {
    try {
        $self = Get-ScheduledTask -TaskName 'MAA-Refresh' -ErrorAction Stop
        $hasCadence = $false
        foreach ($t in $self.Triggers) {
            if ($t.Repetition -and $t.Repetition.Interval) {
                try {
                    if ([System.Xml.XmlConvert]::ToTimeSpan($t.Repetition.Interval).TotalMinutes -eq 5) { $hasCadence = $true }
                }
                catch { }
            }
        }
        if (-not $hasCadence) {
            Write-Log 'adding a 5-minute watchdog cadence to the MAA-Refresh task'
            $cadence = New-ScheduledTaskTrigger -Daily -At '00:00'
            $cadence.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
            Set-ScheduledTask -TaskName 'MAA-Refresh' -Trigger $cadence | Out-Null
            Write-Log 'cadence added: MAA-Refresh runs every 5 minutes from now on.'
        }
    }
    catch {
        Write-Log ('could not adjust the MAA-Refresh cadence: {0}' -f $_.Exception.Message)
    }
}

# The task used to run powershell.exe directly, and Windows always flashes a console
# window for a moment (that is the script window you see popping up every 10 minutes;
# -WindowStyle Hidden cannot prevent it). Running through wscript.exe -- a
# GUI-subsystem host -- with window style 0 creates no console at all.
if ($elevated) {
    try {
        $vbs = Join-Path (Split-Path -Parent $PSCommandPath) 'run-hidden.vbs'
        $self = Get-ScheduledTask -TaskName 'MAA-Refresh' -ErrorAction Stop
        if ($self.Actions[0].Execute -notlike '*wscript.exe') {
            if (Test-Path -LiteralPath $vbs) {
                Write-Log 'switching MAA-Refresh to the windowless wscript launcher'
                $newAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\wscript.exe') -Argument ('//B "{0}"' -f $vbs)
                Set-ScheduledTask -TaskName 'MAA-Refresh' -Action $newAction | Out-Null
                $now = Get-ScheduledTask -TaskName 'MAA-Refresh'
                Write-Log ('MAA-Refresh action is now: {0} {1}' -f $now.Actions[0].Execute, $now.Actions[0].Arguments)
            }
            else {
                Write-Log ('windowless launcher not found at {0}; keeping the current action.' -f $vbs)
            }
        }
    }
    catch {
        Write-Log ('could not switch to the windowless launcher: {0}' -f $_.Exception.Message)
    }
}

# External trigger: create start-run.flag to kick off a run right now (used for
# testing, and by anything that wants a run without waiting for a timer slot).
$flag = Join-Path (Split-Path -Parent $PSCommandPath) 'start-run.flag'
if (Test-Path -LiteralPath $flag) {
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    Write-Log 'start-run.flag found: starting a run now.'
    $null = Start-MaaRunNow -Path $MaaLog
    exit 0
}

$idle       = Get-MaaLogIdleMinutes -Path $MaaLog
$inProgress = Test-MaaTaskInProgress -Path $MaaLog
$preRun     = Test-InPreRunWindow -Windows $PreRunWindows

$reason = $null
if ($Force) { $reason = 'forced' }
elseif ($preRun) { $reason = 'pre-run window: update check before the scheduled run' }
elseif (-not (Test-MaaRunning)) { $reason = 'MAA is not running (crashed or was closed); starting it' }
elseif ($inProgress -and (Get-MaaProgressIdleMinutes -Path $MaaLog) -gt 15) { $reason = ('no task-level progress for {0:N0} min; the run is stuck' -f (Get-MaaProgressIdleMinutes -Path $MaaLog)) }
elseif ($inProgress -and $idle -gt 3 -and -not (Test-EmulatorPresent)) { $reason = 'the emulator died mid-run (its VM processes are gone); recovering' }
elseif (Test-MaaStuckRetrying -Path $AsstLog) {
    $adbForCheck = Join-Path $EmulatorDir 'adb.exe'
    if (Test-ScreenFrozen -AdbPath $adbForCheck -Device $Serial) { $reason = 'game screen is frozen: two screencaps identical while MAA burns through its retries' }
}
elseif ($inProgress -and $idle -gt 2) {
    # The 2026-10-12 18:50 hang (Infrast stuck on the reception room) did NOT raise
    # cur_retry at all, so gate on the screen itself: a run that has reported no
    # progress for 2 minutes plus two identical screencaps 20 s apart is frozen.
    $adbForCheck = Join-Path $EmulatorDir 'adb.exe'
    if (Test-ScreenFrozen -AdbPath $adbForCheck -Device $Serial -WaitSeconds 20) { $reason = 'game screen is frozen: identical screencaps 20 s apart while the run reports no progress' }
}
elseif ($inProgress -and $idle -gt $StallMinutes -and (Get-MaaLogIdleMinutes -Path $AsstLog) -gt 3) { $reason = ('wedged task: BOTH logs silent (gui {0:N0} min, core {1:N0} min) -- the core really stopped' -f $idle, (Get-MaaLogIdleMinutes -Path $AsstLog)) }

Write-Log ('start: elevated={0} force={1} preRun={2} inProgress={3} maaRunning={4} logIdle={5:N1}min' -f $elevated, [bool]$Force, $preRun, $inProgress, (Test-MaaRunning), $idle)

if (-not $reason) {
    # A run that ended with task errors gets exactly one automatic retry.
    $verdict = Get-LastRunVerdict -Path $MaaLog
    if ($verdict.RetryWorth -and -not $inProgress) {
        $stateFile = Join-Path (Split-Path -Parent $PSCommandPath) 'refresh-state.json'
        $retriedFor = $null
        if (Test-Path -LiteralPath $stateFile) {
            try { $retriedFor = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).retriedFor } catch { }
        }
        if ($retriedFor -eq $verdict.Key) {
            Write-Log ('run {0} failed with {1} task error(s) but was already retried once; not retrying again.' -f $verdict.Key, $verdict.Errors)
        }
        else {
            Write-Log ('run {0} ended with {1} task error(s); retrying it once.' -f $verdict.Key, $verdict.Errors)
            [IO.File]::WriteAllText($stateFile, ('{{"retriedFor":"{0}","retriedAt":"{1}"}}' -f $verdict.Key, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), [Text.UTF8Encoding]::new($false))
            $null = Start-MaaRunNow -Path $MaaLog
            exit 0
        }
    }
    if ($inProgress) { Write-Log 'a run is in progress; nothing to do.' }
    else { Write-Log 'MAA is idle between runs; nothing to do.' }
    exit 0
}
Write-Log ('acting: {0}' -f $reason)

# A wedged emulator is the usual cause of a wedged task: clear it so that the next
# run boots a fresh instance through ensure-emulator.ps1.
$emuProcs = @(Get-Process -Name 'dnplayer', 'Ld9BoxHeadless', 'Ld9BoxSVC' -ErrorAction SilentlyContinue)
if ($emuProcs.Count -eq 0) {
    Write-Log 'no emulator processes running.'
}
else {
    # A stall means MAA can get nothing out of the guest. Usually the frozen part
    # is the game renderer while a plain "getprop" still answers, so a stall always
    # gets a fresh emulator; otherwise only a dead one is replaced.
    $replace = ($reason -like 'wedged task*') -or ($reason -like 'game screen is frozen*') -or ($reason -like 'the emulator died*') -or ($reason -like 'no task-level progress*')
    $adb = Join-Path $EmulatorDir 'adb.exe'
    if (-not $replace) {
        if (Test-EmulatorHealthy -AdbPath $adb -Device $Serial) { Write-Log 'emulator answers ADB; leaving it alone.' }
        else { Write-Log 'emulator does NOT answer ADB; replacing it.'; $replace = $true }
    }
    if ($replace) {
        Write-Log 'killing the emulator so the next run boots a fresh instance through ensure-emulator.ps1.'
        Stop-WedgedEmulator -Dir $EmulatorDir
    }
}

# Stop MAA: the scheduler first, then a forced kill (self-updates orphan it).
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { Write-Log ('Stop-ScheduledTask failed: {0}' -f $_.Exception.Message) }
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and (Get-Process -Name 'MAA' -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2 }
if (Get-Process -Name 'MAA' -ErrorAction SilentlyContinue) {
    Write-Log 'MAA still alive (likely restarted by its own updater, so outside the task); killing the process.'
    try { Stop-Process -Name 'MAA' -Force -ErrorAction Stop; Write-Log 'MAA killed.' }
    catch {
        Write-Log ('Could not kill MAA: {0}' -f $_.Exception.Message)
        Write-Log 'Hint: this script must run elevated (scheduled task MAA-Refresh).'
        exit 1
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name 'MAA' -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2 }
}
$left = @(Get-Process -Name 'MAA' -ErrorAction SilentlyContinue).Count
if ($left -gt 0) { Write-Log ('MAA still running after {0}s; starting a second instance anyway (it will just activate the existing window).' -f $WaitSeconds) }
else { Write-Log 'MAA stopped cleanly.' }

# Update the game resources while MAA is down (it loads them at startup). Only on a
# pre-run refresh: a stall recovery should stay quick.
# Normal state: let the timers drive runs, not the launch.
if ($preRun) { $null = Set-MaaRunDirectly -Path $ConfigPath -Value $false }

if (-not $SkipResourceUpdate -and ($preRun -or $Force)) {
    Update-MaaResource -Dir $ResourceDir -VersionUrl $ResourceVersionUrl -ZipUrl $ResourceZipUrl -TimeoutSeconds $ResourceTimeoutSeconds
}

# Start MAA and make sure it is actually healthy -- and retry once if it is not.
$attempt = 0
while ($attempt -lt 2) {
    $attempt++
    Start-Sleep -Seconds 5          # let the previous instance finish its shutdown
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Log ('MAA started (attempt {0}); it will re-check program and resource updates on startup.' -f $attempt)
    }
    catch {
        Write-Log ('Start-ScheduledTask failed: {0}' -f $_.Exception.Message)
        exit 1
    }

    Start-Sleep -Seconds 20
    if (Test-MaaHealthy -Path $MaaLog) {
        Write-Log ('MAA is up and healthy (attempt {0}).' -f $attempt)
        # A recovery interrupts whatever run was in flight; give that run a fresh
        # start (once per run, tracked in the same state file as the failure retry).
        if ($reason -like 'wedged task*' -or $reason -like 'game screen is frozen*' -or $reason -like 'the emulator died*' -or $reason -like 'no task-level progress*') {
            $verdict = Get-LastRunVerdict -Path $MaaLog
            if ($verdict.Key) {
                $stateFile = Join-Path (Split-Path -Parent $PSCommandPath) 'refresh-state.json'
                $retriedFor = $null
                if (Test-Path -LiteralPath $stateFile) {
                    try { $retriedFor = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).retriedFor } catch { }
                }
                if ($retriedFor -ne $verdict.Key) {
                    [IO.File]::WriteAllText($stateFile, ('{{"retriedFor":"{0}","retriedAt":"{1}","why":"recovery"}}' -f $verdict.Key, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), [Text.UTF8Encoding]::new($false))
                    Write-Log ('starting a fresh run to replace the interrupted one ({0}).' -f $verdict.Key)
                    $null = Start-MaaRunNow -Path $MaaLog
                }
                else {
                    Write-Log ('the interrupted run ({0}) was already retried once; not starting another.' -f $verdict.Key)
                }
            }
        }
        exit 0
    }

    Write-Log ('MAA did not come up healthy on attempt {0}; tearing it down and retrying.' -f $attempt)
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 5
    if (Test-MaaRunning) {
        try { Stop-Process -Name 'MAA' -Force -ErrorAction Stop } catch { Write-Log ('could not kill the unhealthy MAA: {0}' -f $_.Exception.Message) }
    }
    Start-Sleep -Seconds 5
}

Write-Log 'ERROR: MAA did not come back healthy after 2 attempts. Check the installation (a failed update can leave it half-updated).'
exit 1
