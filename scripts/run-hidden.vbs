' run-hidden.vbs -- launch the MAA refresh/watchdog with NO visible window at all.
'
' Why this exists: the task used to run powershell.exe directly. Windows creates a
' console window for it and only then applies -WindowStyle Hidden, so a script
' window flashed on screen every 10 minutes. wscript.exe is a GUI-subsystem host,
' and WshShell.Run with window style 0 creates the console already hidden, so
' nothing ever appears.
'
' Registered as the action of scheduled task "MAA-Refresh":
'   C:\Windows\System32\wscript.exe //B "C:\MAA\scripts\run-hidden.vbs"
'
' ASCII only on purpose (project convention).
Set sh = CreateObject("WScript.Shell")
cmd = """C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\MAA\scripts\refresh-maa.ps1"""
sh.Run cmd, 0, False
