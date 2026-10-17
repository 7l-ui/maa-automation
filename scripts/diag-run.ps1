<#
diag-run.ps1 -- watch one MAA run and capture evidence the moment something fails.

It tails MAA's log, prints the interesting lines, and grabs an emulator screenshot
right after any error/stall plus one every few minutes, so a failure can be
diagnosed from the actual game screen instead of guessed at.

ASCII only on purpose (PowerShell 5.1 reads BOM-less .ps1 as the ANSI codepage).
#>
[CmdletBinding()]
param(
    [string]$MaaLog = 'C:\MAA\debug\gui.log',
    [string]$Adb    = 'C:\leidian\LDPlayer9\adb.exe',
    [string]$Serial = 'emulator-5554',
    [string]$OutDir = 'C:\MAA\automation\diag',
    [int]$Minutes  = 25,
    [int]$ShotEverySeconds = 240
)

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = Join-Path $OutDir "diag-$stamp.log"

function Say([string]$m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    try { [IO.File]::AppendAllText($report, $line + "`r`n", [Text.UTF8Encoding]::new($false)) } catch { }
    Write-Output $line
}

function Shot([string]$tag) {
    $o = "$env:TEMP\diag-o.txt"; $e = "$env:TEMP\diag-e.txt"
    $png = Join-Path $OutDir ("shot-{0}-{1}.png" -f $tag, (Get-Date -Format 'HHmmss'))
    $p = Start-Process -FilePath $Adb -ArgumentList @('-s', $Serial, 'shell', 'screencap', '-p', '/sdcard/diag.png') -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e
    $ok = $false; try { Wait-Process -Id $p.Id -Timeout 25 -ErrorAction Stop; $ok = $true } catch { try { Stop-Process -Id $p.Id -Force } catch { } }
    if (-not $ok) { Say "screenshot FAILED (adb shell timed out) [$tag]"; return }
    $p2 = Start-Process -FilePath $Adb -ArgumentList @('-s', $Serial, 'pull', '/sdcard/diag.png', $png) -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e
    $ok2 = $false; try { Wait-Process -Id $p2.Id -Timeout 25 -ErrorAction Stop; $ok2 = $true } catch { try { Stop-Process -Id $p2.Id -Force } catch { } }
    if ($ok2 -and (Test-Path -LiteralPath $png)) { Say ("screenshot saved: {0}" -f (Split-Path $png -Leaf)) }
    else { Say "screenshot pull failed [$tag]" }
}

Say ("watching {0} for {1} min, screenshots -> {2}" -f $MaaLog, $Minutes, $OutDir)
$seen = @(Get-Content -LiteralPath $MaaLog -Encoding UTF8).Count
$deadline = (Get-Date).AddMinutes($Minutes)
$lastShot = Get-Date
$shotCount = 0

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 8
    $all = @(Get-Content -LiteralPath $MaaLog -Encoding UTF8)
    if ($all.Count -gt $seen) {
        $new = $all[$seen..($all.Count - 1)]
        $seen = $all.Count
        foreach ($l in $new) {
            $t = $l.Trim()
            if ($t -match 'Scheduled start|开始任务|完成任务|任务出错|连接失败|停滞|Post actions|开始行动|理智:') {
                Say ($t.Substring(0, [Math]::Min(150, $t.Length)))
            }
        }
        $joined = $new -join "`n"
        if ($joined -match '任务出错|连接失败|停滞') {
            Shot 'fail'
            $shotCount++
            $lastShot = Get-Date
        }
    }
    if (((Get-Date) - $lastShot).TotalSeconds -ge $ShotEverySeconds) {
        Shot 'tick'
        $shotCount++
        $lastShot = Get-Date
    }
}

Say ("watch window over; screenshots taken: {0}" -f $shotCount)
