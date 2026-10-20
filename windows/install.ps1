# Install heard on Windows. Copies heard, heard-daemon, heard-ui and the heard.cmd wrapper into
# %USERPROFILE%\.local\bin and starts heard-daemon (hidden, paused) and the heard-ui overlay at every logon:
# as Scheduled Tasks, or as Startup-folder shortcuts if Task Scheduler refuses (some managed machines).
#
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1              install or update, then start
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 -NoTask      only install the files
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Uninstall   stop and remove (transcripts and logs are kept)
param([switch]$NoTask, [switch]$Uninstall)
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $env:USERPROFILE ".local\bin"
$data = Join-Path $env:USERPROFILE ".local\share\heard"
$startup = [Environment]::GetFolderPath("Startup")
$names = @("heard-daemon", "heard-ui")
$tasks = @{ "heard-daemon" = "heard"; "heard-ui" = "heard-ui" }

function Stop-Heard {
    foreach ($task in $tasks.Values) {
        if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        }
    }
    # Stopping a task ends only its launcher, so also end the wscript / cmd / uv / python processes behind it.
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and
                       ($_.CommandLine -like "*\.local\bin\heard-daemon*" -or $_.CommandLine -like "*\.local\bin\heard-ui*") } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Stop-Heard
    foreach ($task in $tasks.Values) { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue }
    foreach ($name in $names) { Remove-Item (Join-Path $startup "$name.lnk") -ErrorAction SilentlyContinue }
    foreach ($file in @("heard", "heard-daemon", "heard-ui", "heard.cmd", "heard-daemon.vbs", "heard-ui.vbs")) {
        Remove-Item (Join-Path $bin $file) -ErrorAction SilentlyContinue
    }
    Write-Host "heard is uninstalled. Transcripts stay in $data, call logs in $env:USERPROFILE\Documents\heard."
    exit 0
}

$uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uv) { throw "uv not found: install it first (winget install astral-sh.uv), then open a new PowerShell" }

Stop-Heard
New-Item -ItemType Directory -Force $bin, $data | Out-Null
Copy-Item (Join-Path $repo "heard"), (Join-Path $repo "heard-daemon"), (Join-Path $repo "heard-ui"), (Join-Path $PSScriptRoot "heard.cmd") $bin -Force

# A VBScript launcher runs each script with no console window and passes its exit code back to Task Scheduler.
# Written as UTF-16 so a user folder with accents or non-Latin letters still works.
$launchers = @{}
foreach ($name in $names) {
    $script = Join-Path $bin $name
    $log = Join-Path $data "$name.log"
    $launcher = Join-Path $bin "$name.vbs"
    @"
Set shell = CreateObject("WScript.Shell")
WScript.Quit shell.Run("cmd /c """"$uv"" run --script ""$script"" >> ""$log"" 2>&1""", 0, True)
"@ | Set-Content -Path $launcher -Encoding Unicode
    $launchers[$name] = $launcher
}
Write-Host "installed heard, heard-daemon, heard-ui and heard.cmd in $bin"

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath -or ($userPath -split ";") -notcontains $bin) {
    [Environment]::SetEnvironmentVariable("Path", (($userPath, $bin) | Where-Object { $_ }) -join ";", "User")
    Write-Host ("added " + $bin + " to your user PATH; open a new terminal to use the 'heard' command")
}
if ($NoTask) { exit 0 }

try {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $daemonSettings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $uiSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $tasks["heard-daemon"] -Trigger $trigger -Settings $daemonSettings -Force `
        -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$($launchers['heard-daemon'])`"") `
        -Description "heard: local transcript of calls. Read-only capture, local Whisper, starts paused." | Out-Null
    Register-ScheduledTask -TaskName $tasks["heard-ui"] -Trigger $trigger -Settings $uiSettings -Force `
        -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$($launchers['heard-ui'])`"") `
        -Description "heard overlay: Start listening / Pause, live transcript, Library." | Out-Null
    foreach ($name in $names) { Remove-Item (Join-Path $startup "$name.lnk") -ErrorAction SilentlyContinue }
    foreach ($name in $names) { Start-ScheduledTask -TaskName $tasks[$name] }
    $how = "Scheduled Tasks 'heard' (daemon, restarted if it fails) and 'heard-ui' (overlay)"
} catch {
    Write-Warning ("Task Scheduler refused (" + $_.Exception.Message + "); using Startup-folder shortcuts instead.")
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in $names) {
        $link = $shell.CreateShortcut((Join-Path $startup "$name.lnk"))
        $link.TargetPath = "wscript.exe"
        $link.Arguments = "`"$($launchers[$name])`""
        $link.Save()
        Start-Process -FilePath "wscript.exe" -ArgumentList "`"$($launchers[$name])`""
    }
    $how = "shortcuts in your Startup folder"
}

Write-Host @"

heard is running as $how.
The first start downloads Python packages and the speech model, which takes a few minutes. Watch it with:
  Get-Content -Wait "$data\heard-daemon.log"
Nothing is captured until you press Start listening in the overlay (or Ctrl+Shift+L, or 'heard resume').
Update: git pull, then run this script again. Uninstall: run it with -Uninstall.
"@
