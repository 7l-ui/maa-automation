<#
  MAA "PreRunScript" hook for the emulator (LDPlayer) setup.

  Why this exists:
    Measured behaviour: with LDPlayer fully closed, a timer-triggered run only
    logs a "trying to start the emulator" line, retries the ADB connection
    ~5 times over ~14 s and then gives up with a connection-failure error.
    MAA's extras showed "pid":-1, i.e. it looks for a running emulator process
    and has nothing to restart. Its StartEmulator option is documented as
    running at MAA startup, not before a timer-triggered chain.
    So the emulator has to be brought up by a hook, exactly like the PC client.

  Why it also recovers from stale processes (added 2026-09-24):
    Measured failure, 2026-09-23: both scheduled runs (01:00 and 09:00) failed.
    MAA had reported "Emulator at index 0 closed through console" successfully
    after the previous run, but LDPlayer had only closed the VM instance and
    left a half-dead state behind: a leftover dnplayer.exe stub (6 MB, showing a
    "new notification" window) plus an Ld9BoxHeadless process that never
    answered ADB again. MAA's log for that run shows the real symptom:
        name: LDPlayer, extras: {"path":"...","index":0,"pid":-1}
        handle: ..., return: false          (x5, then "connect failed")
    The old version of this hook saw Ld9BoxHeadless present, logged
    "VM process present but ADB not ready yet; waiting" and simply waited the
    full 300 s budget for a VM that was never going to come back.
    So: stale processes now get a short grace period to answer ADB, and are
    force-killed and replaced with a clean start if they do not.

  What it does:
    1. If ADB already reports the device, exit immediately (idempotent) - this
       also guarantees a session you started by hand is never disturbed.
    2. If emulator processes exist but ADB does not answer within
       StaleGraceSeconds, kill them and reset the ADB server.
    3. Start dnplayer.exe and poll until sys.boot_completed=1, then exit.
    4. If an attempt times out while ADB was never seen, kill the emulator and
       retry once with a clean start. An emulator that HAS answered ADB is
       never killed, so a manual session cannot be interrupted.

  Unlike the PC-client hook there is no matching close hook: MAA's own
  PostActions = ExitEmulator closes the emulator, and that works when MAA runs
  elevated (a normal-privilege MAA gets "Access denied" reading the emulator's
  main module when the emulator was started elevated).

  Invoked by MAA as a command line:
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\MAA\scripts\ensure-emulator.ps1"

  Keep this file pure ASCII: Windows PowerShell 5.1 decodes a BOM-less .ps1 with
  the system ANSI code page, which corrupts non-ASCII source.
#>
param(
    [string]$EmulatorDir = 'C:\leidian\LDPlayer9',
    [string]$Address = 'emulator-5554',
    [int]$TimeoutSeconds = 300,
    [int]$SettleSeconds = 20,
    [int]$StaleGraceSeconds = 45,
    [int]$MaxAttempts = 2
)

$ErrorActionPreference = 'Stop'
$dnplayer = Join-Path $EmulatorDir 'dnplayer.exe'
$adb = Join-Path $EmulatorDir 'adb.exe'
$logFile = Join-Path $PSScriptRoot 'maa-hooks.log'
$processNames = @('dnplayer', 'Ld9BoxHeadless', 'Ld9BoxSVC')

function Write-HookLog([string]$Message) {
    $line = '{0} [ensure-emulator] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Test-AdbDevice {
    try {
        $out = & $adb -s $Address get-state 2>&1 | Out-String
        return ($out -match 'device')
    } catch { return $false }
}

function Test-BootCompleted {
    try {
        $out = & $adb -s $Address shell getprop sys.boot_completed 2>&1 | Out-String
        return ($out -match '1')
    } catch { return $false }
}

function Get-EmulatorProcesses {
    return @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
}

function Stop-EmulatorProcesses {
    foreach ($name in $processNames) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-HookLog ('killed leftover {0} (PID {1})' -f $name, $proc.Id)
            } catch {
                Write-HookLog ('could not kill {0} (PID {1}): {2}' -f $name, $proc.Id, $_.Exception.Message)
            }
        }
    }
    Start-Sleep -Seconds 6
}

function Reset-AdbServer {
    # adb prints its normal startup notice ("daemon not running; starting now")
    # to stderr, which $ErrorActionPreference = 'Stop' would turn into a
    # terminating error - that produced a misleading "restart failed" log line.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $adb kill-server 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $out = (& $adb start-server 2>&1 | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($out -match 'daemon started successfully|already running') {
        Write-HookLog 'ADB server restarted'
    } else {
        Write-HookLog ('ADB server start output: ' + ($out -replace '\s+', ' '))
    }
}

try {
    # 1. Already healthy? Then leave everything alone.
    if (Test-AdbDevice) {
        if (Test-BootCompleted) {
            Write-HookLog 'emulator already online and booted; nothing to do.'
            exit 0
        }
        Write-HookLog 'ADB device online but Android has not finished booting; waiting.'
    } else {
        # 2. Leftovers from a previous run may be half-dead. Give them a short
        #    grace period, then replace them with a clean start.
        $leftover = Get-EmulatorProcesses
        if ($leftover.Count -gt 0) {
            $names = (($leftover | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ',')
            Write-HookLog ('stale emulator processes present ({0}); giving them {1}s to answer ADB.' -f $names, $StaleGraceSeconds)
            $grace = (Get-Date).AddSeconds($StaleGraceSeconds)
            while ((Get-Date) -lt $grace -and -not (Test-AdbDevice)) {
                Start-Sleep -Seconds 3
            }
            if (-not (Test-AdbDevice)) {
                Write-HookLog 'stale processes never answered ADB; killing them and starting clean.'
                Stop-EmulatorProcesses
                Reset-AdbServer
            }
        }
    }

    # 3. Bring the emulator up, with one clean restart if an attempt stalls.
    $attemptSeconds = [Math]::Max(60, [int]($TimeoutSeconds / $MaxAttempts))
    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        if (-not (Test-AdbDevice)) {
            Start-Process -FilePath $dnplayer -WorkingDirectory $EmulatorDir | Out-Null
            Write-HookLog ('started dnplayer.exe (attempt {0}/{1})' -f $attempt, $MaxAttempts)
        }

        $deadline = (Get-Date).AddSeconds($attemptSeconds)
        $adbSeen = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-AdbDevice) {
                if (-not $adbSeen) {
                    $adbSeen = $true
                    Write-HookLog 'ADB device is up; waiting for Android boot to finish.'
                }
                if (Test-BootCompleted) {
                    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
                    # A failed MAA connect leaves a stuck `settings` process behind,
                    # which keeps the provider locked so every later connect fails too
                    # (feedback loop: 2026-10-15 01:11 and 09:05, five failures in a row).
                    # Clear any leftovers before testing the provider.
                    & $adb -s $Address shell 'pkill -f "settings get"; killall settings' 2>&1 | Out-Null
                    Start-Sleep -Seconds 2
                    # MAA identifies the device with `settings get secure android_id`.
                    # When the guest's settings provider wedges, that call hangs and MAA
                    # reports a connection failure (measured 2026-10-12 19:21 and
                    # 2026-10-14 01:33 / 09:05). Verify it here; soft-restart Android
                    # if it does not answer.
                    $settingsOk = $false
                    for ($i = 0; $i -lt 3 -and -not $settingsOk; $i++) {
                        $tmp = "$env:TEMP\hook-settings.txt"
                        $proc = Start-Process -FilePath $adb -ArgumentList @('-s', $Address, 'shell', 'settings', 'get', 'secure', 'android_id') -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err"
                        $done = $false
                        try { Wait-Process -Id $proc.Id -Timeout 12 -ErrorAction Stop; $done = $true } catch { }
                        if ($done) { $settingsOk = $true }
                        else {
                            try { Stop-Process -Id $proc.Id -Force } catch { }
                            Write-HookLog ('settings provider did not answer (attempt {0}); soft-restarting Android.' -f ($i + 1))
                            & $adb -s $Address shell stop 2>&1 | Out-Null
                            Start-Sleep -Seconds 5
                            & $adb -s $Address shell start 2>&1 | Out-Null
                            Start-Sleep -Seconds 20
                        }
                    }
                    if ($settingsOk) { Write-HookLog 'settings provider answers; MAA can identify the device.' }
                    else { Write-HookLog 'WARNING: settings provider still not answering; handing over anyway.' }
                    # boot_completed is NOT enough for MAA: it also needs the renderer
                    # to answer, i.e. a working screencap. Both the 2026-10-08 and the
                    # 10-12 evening failures were a connect failure right after a boot whose
                    # readiness check had only looked at boot_completed.
                    $ready = $false
                    for ($i = 0; $i -lt 6 -and -not $ready; $i++) {
                        $out = & $adb -s $Address shell screencap -p /sdcard/hook-ready.png 2>&1 | Out-String
                        if ($LASTEXITCODE -eq 0 -and $out -notmatch 'error|Exception') { $ready = $true }
                        elseif ($i -lt 5) { Start-Sleep -Seconds 5 }
                    }
                    if ($ready) { Write-HookLog 'screencap works; emulator is ready for MAA.' }
                    else { Write-HookLog 'WARNING: screencap still failing; handing over to MAA anyway.' }
                    Write-HookLog 'emulator booted and ready.'
                    exit 0
                }
            }
            Start-Sleep -Seconds 4
        }

        Write-HookLog ('attempt {0}/{1} timed out after {2}s (adbSeen={3}).' -f $attempt, $MaxAttempts, $attemptSeconds, $adbSeen)

        # Only ever kill a VM that never answered ADB: a live one may be a
        # manual session the user is playing in.
        if (-not $adbSeen -and $attempt -lt $MaxAttempts) {
            Write-HookLog 'no ADB response at all; killing the emulator and retrying clean.'
            Stop-EmulatorProcesses
            Reset-AdbServer
        } else {
            break
        }
    }

    Write-HookLog ('FAILED after {0} attempt(s) in {1}s: emulator did not become ready.' -f $attempt, $TimeoutSeconds)
    exit 1
} catch {
    Write-HookLog ('ERROR: ' + $_.Exception.Message)
    exit 1
}
