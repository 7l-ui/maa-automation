<#
verify-run.ps1 -- start one run through the watchdog and report how it went.

It drops the start-run.flag (the watchdog's "kick off a run now" switch), triggers
the MAA-Refresh task, then follows gui.log until the chain ends and prints a
verdict: how many task-level errors the run had and whether it reached the final
task (Award). Used to measure the success rate after a fix.

ASCII only on purpose (PowerShell 5.1 reads BOM-less .ps1 as the ANSI codepage).
#>
[CmdletBinding()]
param(
    [string]$MaaLog   = 'C:\MAA\debug\gui.log',
    [string]$FlagFile = 'C:\MAA\scripts\start-run.flag',
    [string]$TaskName = 'MAA-Refresh',
    [int]$TimeoutMinutes = 60
)

function Say([string]$m) { Write-Output ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

# 1. ask the watchdog for a run
New-Item -ItemType File -Path $FlagFile -Force | Out-Null
Say ('flag created: {0}' -f $FlagFile)
Start-ScheduledTask -TaskName $TaskName
Say ('triggered task {0}; waiting for the run to start...' -f $TaskName)

$seen = @(Get-Content -LiteralPath $MaaLog -Encoding UTF8).Count
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$started = $false
$lastActivity = Get-Date
$errors = 0
$reachedAward = $false
$ended = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $all = @(Get-Content -LiteralPath $MaaLog -Encoding UTF8)
    if ($all.Count -le $seen) { continue }
    $new = $all[$seen..($all.Count - 1)]
    $seen = $all.Count
    $lastActivity = Get-Date
    foreach ($l in $new) {
        $t = $l.Trim()
        if ($t -match '开始前脚本') { $started = $true; Say 'run started (PreRunScript)' }
        elseif ($t -match '\[ERR\]\[TaskQueueViewModel\]') { $errors++; Say ('ERROR: ' + $t.Substring(0, [Math]::Min(130, $t.Length))) }
        elseif ($t -match '完成任务: 领取奖励') { $reachedAward = $true; Say 'reached the final task (Award) OK' }
        elseif ($t -match 'Post actions:') { Say ('run ended: ' + $t.Substring(0, [Math]::Min(120, $t.Length))); $ended = $true }
        elseif ($t -match 'Idle: false to true') { Say 'MAA went idle (run ended)'; $ended = $true }
    }
    if ($ended) { break }
    # a run that has gone quiet for 30 minutes is not going to finish here
    # (a single slow annihilation battle has been measured at 13 min)
    if ($started -and ((Get-Date) - $lastActivity).TotalMinutes -gt 30) { Say 'no log activity for 30 min; giving up on this run'; break }
}

Say ('---- verdict ----')
Say ('started={0} ended={1} reachedAward={2} taskErrors={3}' -f $started, $ended, $reachedAward, $errors)
if ($started -and $ended -and $reachedAward -and $errors -eq 0) { Say 'RESULT: CLEAN SUCCESS' }
elseif ($started -and $reachedAward) { Say 'RESULT: finished but with errors' }
elseif ($started) { Say 'RESULT: FAILED' }
else { Say 'RESULT: no run detected (check the watchdog log)' }
