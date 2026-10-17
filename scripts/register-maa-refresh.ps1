<#
register-maa-refresh.ps1 -- register the "MAA-Refresh" scheduled task.

Run this ONCE as administrator (right-click > Run as administrator, or let the
agent start it with -Verb RunAs and approve the UAC prompt). It has to be
elevated because MAA runs as administrator: the refresh script must be able to
end the MAA process even when MAA was restarted by its own updater and therefore
is no longer a child of the MAA-Autostart task.

What it registers:
  MAA-Refresh -> C:\MAA\scripts\refresh-maa.ps1
  daily at 00:30 and 08:30 (30 min before the 01:00 / 09:00 runs), RunLevel Highest.

ASCII only on purpose (Windows PowerShell 5.1 + BOM-less .ps1 = ANSI codepage).
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'MAA-Refresh',
    [string]$Script   = 'C:\MAA\scripts\refresh-maa.ps1',
    [string[]]$Times  = @('00:30', '08:30'),
    [string]$LogFile  = 'C:\MAA\scripts\maa-hooks.log'
)

function Write-Log([string]$Message) {
    Write-Output $Message
    try {
        $line = '{0} [register-refresh] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.UTF8Encoding]::new($false))
    }
    catch {
        # logging must never break the registration
    }
}

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log ('start: elevated={0} user={1}' -f $isAdmin, $env:USERNAME)

if (-not $isAdmin) {
    Write-Log 'ERROR: this script must run as administrator (MAA runs elevated).'
    exit 1
}

if (-not (Test-Path -LiteralPath $Script)) {
    Write-Log ("ERROR: script not found: {0}" -f $Script)
    exit 1
}

try {
    $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Script
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $argument

    $triggers = @()
    foreach ($t in $Times) {
        $triggers += New-ScheduledTaskTrigger -Daily -At $t
    }

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew

    # Mirror MAA-Autostart: plain user name, Interactive logon, Highest run level.
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null

    $task = Get-ScheduledTask -TaskName $TaskName
    Write-Log ("registered {0}: state={1} runlevel={2} user={3} triggers={4}" -f `
        $task.TaskName, $task.State, $task.Principal.RunLevel, $task.Principal.UserId, (($Times) -join '/'))
    Write-Log ("action: {0} {1}" -f $task.Actions[0].Execute, $task.Actions[0].Arguments)
    exit 0
}
catch {
    Write-Log ("ERROR while registering: {0}" -f $_.Exception.Message)
    exit 1
}
