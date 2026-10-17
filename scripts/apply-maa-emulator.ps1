<#
  Switch the MAA setup from the PC client to an emulator (LDPlayer / ADB).

  What changes compared with the PC-client setup:
    ConnectSettings.Config          -> LDPlayer
    ConnectSettings.Extras.LDPlayer -> enabled, pointed at EmulatorPath
    StartUpSettings.StartEmulator   -> true          (MAA starts the emulator itself)
    RestartEmulatorWhenAdbFailed    -> true          (covers a timer firing while the emulator is off)
    StartUpSettings.EmulatorPath    -> EmulatorPath
    StartUpSettings.EmulatorWaitSeconds -> 120
    PostActions                     -> ExitEmulator  (native; replaces close-game.ps1)
    PreRunScript                    -> ensure-emulator.ps1 (MAA cannot cold-start the emulator)
    PostRunScript                   -> cleared
    ExecuteScriptOnManualStop       -> false
    RunDirectly                     -> false         (unchanged: scheduling drives everything)

  Not changed: the timer slots and the enabled task list.

  Notes / caveats found while building this:
    - PostActions is only honoured in ADB mode. MAA has a method named
      ClearUnsupportedPostActionsForAttachWindow, which is why the PC-client
      profile could only keep "None".
    - Measured: with LDPlayer fully closed, a timer-triggered run only logs a
      "trying to start the emulator" line, retries the ADB connection ~5 times
      over ~13 s, then fails. MAA's extras reported "pid":-1: its StartEmulator
      option runs at MAA startup and it has no process to restart mid-chain. So
      the emulator needs a PreRunScript, exactly like the PC client needed one.
    - PostActions does not run on a manual stop, so a manual stop can leave the
      emulator running. Re-enable a PostRunScript if that matters.
    - A normal-privilege MAA cannot close an elevated emulator ("Access denied"
      reading the emulator's main module), while an elevated MAA can close both.
      Keep MAA elevated via the scheduled task unless the emulator is always
      started from its non-elevated shortcut.

  Keep this file pure ASCII (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\MAA\config\gui.new.json',
    [string]$ScriptDir = 'C:\MAA\scripts',
    [string]$EmulatorPath = 'C:\leidian\LDPlayer9',
    [int]$InstanceIndex = 0,
    [int]$EmulatorWaitSeconds = 120,
    [string[]]$Times = @('04:30', '12:30', '20:30'),
    [string[]]$Tasks = @(),
    [switch]$KeepTimers,
    [switch]$KeepScripts,
    [switch]$KeepPostAction
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$Message) { Write-Host "[maa-emulator] $Message" }

$maa = @(Get-Process -Name MAA -ErrorAction SilentlyContinue)
if ($maa.Count -gt 0) {
    throw "MAA is running (PID $($maa.Id -join ', ')). Close MAA first: it rewrites gui.new.json on exit and would discard these changes."
}
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
if (-not (Test-Path -LiteralPath $EmulatorPath)) { throw "Emulator path not found: $EmulatorPath" }

$slots = @()
foreach ($t in $Times) {
    if ($t -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') { throw "Bad time value '$t'; expected HH:mm (24-hour)." }
    $parts = $t -split ':'
    $slots += [pscustomobject]@{ Hour = [int]$parts[0]; Minute = [int]$parts[1] }
}
if ($slots.Count -gt 8) { throw "MAA supports at most 8 schedule slots; got $($slots.Count)." }

$backup = '{0}.bak-emulator-{1}' -f $ConfigPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $ConfigPath -Destination $backup
Write-Step "backup: $backup"

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$profile = $cfg.Current
$target = $cfg.Configurations.$profile
if (-not $target) { throw "Profile '$profile' not found." }

$conn = $target.Gui.ConnectSettings
$conn.Config = 'LDPlayer'
$conn.Extras.LDPlayer.IsEnabled = $true
$conn.Extras.LDPlayer.EmulatorPath = $EmulatorPath
$conn.Extras.LDPlayer.InstanceIndex = $InstanceIndex
$conn.Extras.LDPlayer.ManualSetIndex = $false
Write-Step 'ConnectSettings -> LDPlayer'

$start = $target.Gui.StartUpSettings
$start.StartEmulator = $true
$start.RestartEmulatorWhenAdbFailed = $true
$start.EmulatorPath = $EmulatorPath
$start.EmulatorAddCommand = ''
$start.EmulatorWaitSeconds = $EmulatorWaitSeconds
$start.RunDirectly = $false
Write-Step 'StartUpSettings -> start emulator, wait port, RunDirectly stays false'

if (-not $KeepPostAction) {
    $target.Gui.PostActions = 'ExitEmulator'
    Write-Step 'PostActions -> ExitEmulator'
}

if (-not $KeepScripts) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $prefix = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' -f $psExe
    $target.Gui.RuntimeSettings.PreRunScript = $prefix + ('"{0}"' -f (Join-Path $ScriptDir 'ensure-emulator.ps1'))
    $target.Gui.RuntimeSettings.PostRunScript = ''
    $target.Gui.RuntimeSettings.ExecuteScriptOnManualStop = $false
    Write-Step 'PreRunScript -> ensure-emulator.ps1; PostRunScript cleared'
}

if ($Tasks.Count -gt 0) {
    $known = @($target.TaskQueue | ForEach-Object { $_.TaskType })
    foreach ($t in $Tasks) {
        if ($known -notcontains $t) { throw "Unknown task type '$t'. Known types: $($known -join ', ')" }
    }
    if ($Tasks.Count -eq 1 -and $Tasks[0] -eq 'StartUp') {
        Write-Warning 'Only StartUp enabled: MAA disables that task on startup (a login-only run is treated as pointless), leaving nothing to run.'
    }
    foreach ($item in $target.TaskQueue) { $item.IsEnable = ($Tasks -contains $item.TaskType) }
    Write-Step ("tasks enabled: " + ($Tasks -join ', '))
}

if (-not $KeepTimers) {
    for ($i = 0; $i -lt $cfg.Timers.List.Count; $i++) {
        if ($i -lt $slots.Count) {
            $cfg.Timers.List[$i].IsEnabled = $true
            $cfg.Timers.List[$i].Hour = $slots[$i].Hour
            $cfg.Timers.List[$i].Minute = $slots[$i].Minute
            $cfg.Timers.List[$i].Config = $profile
        } else {
            $cfg.Timers.List[$i].IsEnabled = $false
        }
    }
    Write-Step ("schedule slots enabled: " + (($slots | ForEach-Object { '{0:00}:{1:00}' -f $_.Hour, $_.Minute }) -join ', '))
}

$json = $cfg | ConvertTo-Json -Depth 100
$temp = $ConfigPath + '.maa-emulator.tmp'
[IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
$replaced = $false
try {
    [IO.File]::Replace($temp, $ConfigPath, ($ConfigPath + '.maa-emulator.replace.bak'))
    Remove-Item -LiteralPath ($ConfigPath + '.maa-emulator.replace.bak') -Force -ErrorAction SilentlyContinue
    $replaced = $true
    Write-Step 'config written (File.Replace)'
} catch {
    Write-Step ("File.Replace unavailable ($($_.Exception.Message)); falling back to Move-Item")
}
if (-not $replaced) { Move-Item -LiteralPath $temp -Destination $ConfigPath -Force }

$check = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$c = $check.Configurations.$profile.Gui
if ($c.ConnectSettings.Config -ne 'LDPlayer') { throw 'Verification failed: ConnectSettings.Config did not persist.' }
if (-not $c.StartUpSettings.StartEmulator) { throw 'Verification failed: StartEmulator did not persist.' }
if (-not $KeepPostAction -and $c.PostActions -ne 'ExitEmulator') { throw 'Verification failed: PostActions did not persist.' }
if (-not $KeepScripts) {
    if ($c.RuntimeSettings.PreRunScript -notmatch 'ensure-emulator\.ps1"?\s*$') { throw 'Verification failed: PreRunScript did not persist.' }
    if ($c.RuntimeSettings.PostRunScript) { throw 'Verification failed: PostRunScript should be clear in emulator mode.' }
}
Write-Step ("verified. connect={0} startEmulator={1} postAction={2} preHook={3}" -f `
    $c.ConnectSettings.Config, $c.StartUpSettings.StartEmulator, $c.PostActions, `
    $(if ($c.RuntimeSettings.PreRunScript -match 'ensure-emulator') { 'ensure-emulator.ps1' } else { 'none' }))
$enabled = @($check.Timers.List | Where-Object { $_.IsEnabled })
Write-Step ("timer slots: " + (($enabled | ForEach-Object { '{0:00}:{1:00}' -f $_.Hour, $_.Minute }) -join ', '))
Write-Step 'done. Start MAA and verify it can connect before trusting a scheduled run.'
