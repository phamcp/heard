# Install heard on Windows: copies heard, heard-daemon and the heard.cmd wrapper into
# %USERPROFILE%\.local\bin and registers a Scheduled Task that starts heard-daemon (hidden) at logon
# and restarts it if it dies. Run from PowerShell:  powershell -ExecutionPolicy Bypass -File windows\install.ps1
# Add -NoTask to only install the files.
param([switch]$NoTask)
$ErrorActionPreference = "Stop"

$uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uv) { throw "uv not found: install it first (winget install astral-sh.uv) and reopen PowerShell" }

$repo = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $env:USERPROFILE ".local\bin"
$data = Join-Path $env:USERPROFILE ".local\share\heard"
New-Item -ItemType Directory -Force $bin, $data | Out-Null
Copy-Item (Join-Path $repo "heard"), (Join-Path $repo "heard-daemon"), (Join-Path $PSScriptRoot "heard.cmd") $bin -Force

# A VBScript launcher keeps the daemon's console window hidden while still letting the task see its exit code.
$daemon = Join-Path $bin "heard-daemon"
$log = Join-Path $data "heard.log"
$launcher = Join-Path $bin "heard-daemon.vbs"
@"
Set shell = CreateObject("WScript.Shell")
WScript.Quit shell.Run("cmd /c """"$uv"" run --script ""$daemon"" >> ""$log"" 2>&1""", 0, True)
"@ | Set-Content -Path $launcher -Encoding ASCII
Write-Host "installed heard, heard-daemon and heard.cmd in $bin"

if ($env:Path -notlike "*$bin*") {
    [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$bin", "User")
    Write-Host "added $bin to your user PATH (open a new terminal to use `heard`)"
}
if ($NoTask) { exit 0 }

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$launcher`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "heard" -Action $action -Trigger $trigger -Settings $settings -Force `
    -Description "Local real-time transcript of calls (heard): read-only capture, local Whisper" | Out-Null
Start-ScheduledTask -TaskName "heard"
Write-Host @"
heard is running as the Scheduled Task "heard" (starts at logon, restarts if it stops).
  log:       Get-Content -Wait $log      (the first start downloads the model)
  restart:   Stop-ScheduledTask heard; Start-ScheduledTask heard
  uninstall: Unregister-ScheduledTask heard -Confirm:`$false
"@
