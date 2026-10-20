# Install heard on Windows: copies heard, heard-daemon, heard-ui and the heard.cmd wrapper into
# %USERPROFILE%\.local\bin and registers two Scheduled Tasks that start heard-daemon (hidden, paused) and
# the heard-ui overlay at logon; the daemon task restarts it if it dies. Run from PowerShell:  powershell -ExecutionPolicy Bypass -File windows\install.ps1
# Add -NoTask to only install the files.
param([switch]$NoTask)
$ErrorActionPreference = "Stop"

$uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uv) { throw "uv not found: install it first (winget install astral-sh.uv) and reopen PowerShell" }

$repo = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $env:USERPROFILE ".local\bin"
$data = Join-Path $env:USERPROFILE ".local\share\heard"
New-Item -ItemType Directory -Force $bin, $data | Out-Null
Copy-Item (Join-Path $repo "heard"), (Join-Path $repo "heard-daemon"), (Join-Path $repo "heard-ui"), (Join-Path $PSScriptRoot "heard.cmd") $bin -Force

# A VBScript launcher keeps the daemon's console window hidden while still letting the task see its exit code.
$launchers = @{}
foreach ($name in "heard-daemon", "heard-ui") {
    $script = Join-Path $bin $name
    $log = Join-Path $data "$name.log"
    $launcher = Join-Path $bin "$name.vbs"
    @"
Set shell = CreateObject("WScript.Shell")
WScript.Quit shell.Run("cmd /c """"$uv"" run --script ""$script"" >> ""$log"" 2>&1""", 0, True)
"@ | Set-Content -Path $launcher -Encoding ASCII
    $launchers[$name] = $launcher
}
Write-Host "installed heard, heard-daemon, heard-ui and heard.cmd in $bin"

if ($env:Path -notlike "*$bin*") {
    [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$bin", "User")
    Write-Host "added $bin to your user PATH (open a new terminal to use `heard`)"
}
if ($NoTask) { exit 0 }

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$daemonSettings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$uiSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "heard" -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$($launchers['heard-daemon'])`"") `
    -Trigger $trigger -Settings $daemonSettings -Force `
    -Description "Local real-time transcript of calls (heard): read-only capture, local Whisper, starts paused" | Out-Null
Register-ScheduledTask -TaskName "heard-ui" -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$($launchers['heard-ui'])`"") `
    -Trigger $trigger -Settings $uiSettings -Force -Description "heard overlay (Listening switch, transcript, Assist)" | Out-Null
Start-ScheduledTask -TaskName "heard"
Start-ScheduledTask -TaskName "heard-ui"
Write-Host @"
heard is running: Scheduled Tasks "heard" (daemon, started paused; restarts if it stops) and "heard-ui" (overlay).
  logs:      Get-Content -Wait $data\heard-daemon.log      (the first start downloads the model)
  restart:   Stop-ScheduledTask heard; Start-ScheduledTask heard
  uninstall: Unregister-ScheduledTask heard -Confirm:`$false; Unregister-ScheduledTask heard-ui -Confirm:`$false
Nothing is captured until you turn Listening on (overlay, Ctrl+Shift+L, or 'heard resume').
"@
