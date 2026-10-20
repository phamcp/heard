# heard

A local, real-time transcript of what you hear and say on your desktop, so you can search for what someone
said three minutes ago, whichever app it came from. Linux, macOS and Windows. Capture is off until you turn it
on, and the audio never leaves the machine.

```
$ heard --last 3m
Mon 10:08:26  them: I think the staging rollout is blocked on the IAM change.
Mon 10:08:36    me: Okay, I'll ping the platform team after this.
$ heard "staging rollout"
$ heard -f          # follow live, with an in-progress line for whoever is talking right now
```

Or use the overlay, `heard-ui`: a translucent always-on-top bar, hidden from screen sharing. Start listening
before a call, Stop recording after it: each call becomes a titled Markdown log you can read, copy and search
later in the overlay's Library.

- **Any app:** Zoom, Slack huddles, Google Meet, a browser video. It records the system's default output, not
  a particular app.
- **Both sides:** "them" is everything played to your default output; "me" is your default microphone.
- **Local only:** audio never leaves the machine and is never written to disk. Speech is transcribed by
  [faster-whisper](https://github.com/SYSTRAN/faster-whisper) on your GPU (or CPU) and only the text is stored
  in a SQLite full-text index under `~/.local/share/heard/`, readable only by you.
- **Read-only capture:** it never loads modules, moves streams, or installs a virtual audio device, so it is
  safe to start in the middle of a call. Per platform:
  - Linux: `parec` on the output's monitor source and on the microphone (PulseAudio or PipeWire)
  - macOS: a [Core Audio process tap](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
    on the default output (macOS 14.2+), and the default input device
  - Windows: the WASAPI loopback of the default output, and the default microphone

This fork adds the macOS and Windows ports, the overlay, and conservative defaults to
[ZachGoldberg/heard](https://github.com/ZachGoldberg/heard).

## Privacy defaults

- **Off until you say so.** The daemon starts paused, at every boot and every restart. Capture runs only after
  you turn Listening on (the overlay, its hotkey, or `heard resume`), and the overlay's dot and tray icon are
  red the whole time it does. While paused, no capture process runs at all, so the system's microphone
  indicator (macOS menu bar, Windows taskbar) is off too.
- **Pauses itself** after 3 hours of continuous listening (`HEARD_MAX_LISTEN_MINUTES`), so a switch left on
  does not quietly transcribe the rest of the day.
- **Short memory.** Lines older than 3 days are deleted (`HEARD_RETENTION_DAYS`). Audio is never stored.
- **Owner-only files.** The data folder, database, live captions and the overlay's settings are readable only by
  your user. The daemon log contains status lines, never transcript text.
- **Nothing leaves the machine.** No cloud, no AI service, no network access at all beyond the one-time model
  download.
- **Hidden from screen sharing.** The overlay window is excluded from screen capture on macOS and Windows.

## Requirements

- [uv](https://docs.astral.sh/uv/). `heard-daemon` and `heard-ui` are uv scripts and install their own
  dependencies on the first run (faster-whisper, numpy; PySide6-Essentials for the overlay; on Linux and Windows
  also NVIDIA's pip-packaged cuBLAS/cuDNN, about 1.5 GB, downloaded even without an NVIDIA GPU; on Windows
  PyAudioWPatch, a PortAudio build with WASAPI loopback).
- Optional: an NVIDIA GPU (Linux, Windows). The default model is `large-v3-turbo` on CUDA. Without a usable
  GPU it falls back to `small.en` on the CPU automatically. macOS always uses the CPU (`small.en` by default;
  set `HEARD_MODEL` to try a bigger one on Apple silicon).
- Linux: PulseAudio, or PipeWire with `pipewire-pulse` (`parec`, `pactl`); a systemd user session (optional,
  for running it in the background)
- macOS: 14.2 or newer, and the Xcode Command Line Tools (`xcode-select --install`) to build the small
  `heard-tap` helper
- Windows: 10 or 11 (version 2004 or newer hides the overlay from screen sharing), and
  [uv](https://docs.astral.sh/uv/) (`winget install astral-sh.uv`) and git

## Install

### Linux

```sh
git clone https://github.com/phamcp/heard
install -m 755 heard/heard heard/heard-daemon heard/heard-ui ~/.local/bin/
install -m 644 heard/systemd/heard.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now heard.service
journalctl --user -u heard -f      # first start downloads the model (~1.5 GB for large-v3-turbo)
heard-ui &                         # the overlay (no global hotkeys or screen-share hiding on Linux)
```

### macOS

```sh
git clone https://github.com/phamcp/heard
heard/macos/install.sh             # builds heard-tap, installs to ~/.local/bin, starts the daemon and the overlay
tail -f ~/Library/Logs/heard.log   # first start downloads the model (~500 MB for small.en)
```

The first time you turn Listening on, macOS asks for two permissions, which go to `heard-tap`: **Microphone**,
and **System Audio Recording** (System Settings → Privacy & Security → Screen & System Audio Recording,
"System Audio Recording Only"). Until both are granted the daemon hears silence. Re-run `macos/install.sh`
after pulling changes; a rebuilt `heard-tap` asks for the permissions again.

`launchctl kickstart -k gui/$UID/local.heard` restarts the daemon; `launchctl bootout gui/$UID/local.heard`
and `… local.heard-ui` stop and uninstall the agents. `macos/install.sh --no-agent` only installs the files.

### Windows

In PowerShell (no administrator needed):

```powershell
git clone https://github.com/phamcp/heard
powershell -ExecutionPolicy Bypass -File heard\windows\install.ps1
Get-Content -Wait $env:USERPROFILE\.local\share\heard\heard-daemon.log   # first start downloads packages and the model
```

The installer copies the scripts to `%USERPROFILE%\.local\bin` (and adds it to your PATH for the `heard`
command), then starts the daemon (paused) and the overlay, and again at every logon: as the Scheduled Tasks
"heard" and "heard-ui", or as Startup-folder shortcuts if Task Scheduler refuses. The first start takes a few
minutes while uv downloads Python, the packages and the speech model; the overlay shows "Daemon off" until the
daemon is up. Windows may ask once to allow microphone access for Python.

- **Update:** `git pull`, then run the installer again. It stops the running copy first.
- **Uninstall:** run the installer with `-Uninstall`. Transcripts and call logs are kept.
- **Files only:** `-NoTask` installs without starting anything; then `uv run --script heard-daemon` runs it in a
  terminal.
- **Logs:** `heard-daemon.log` and `heard-ui.log` in `%USERPROFILE%\.local\share\heard`.

## Usage

### The overlay (`heard-ui`)

A bar at the top of the screen, movable, on every Space, excluded from screen sharing:

| Control | |
|---|---|
| **▶ Start listening** (⌘⇧L, Ctrl+Shift+L) | starts (or resumes) capturing and shows the transcript; amber while off |
| **● Listening · Pause** (same key) | red, blinking, with the minutes since the call started; Pause only pauses, the transcript stays |
| **■ Stop recording** | files the transcript shown in the library as a titled log, clears the view, pauses, and opens the Library on it |
| transcript | lines as they land, the sentence in progress dimmed; the search field filters the retained history as you type (word prefixes match; quotes and OR work too), clear it to go back live |
| **Library** | toggles the list of logged calls in your library folder (`~/Documents/heard`), each with its text, Copy log, Show in folder, Delete |
| **Copy transcript** | under the transcript while a call is on screen (or a search is shown): everything shown, as text, to the clipboard |
| ⚙ | the library folder |
| ✕ (⌘⇧H, Ctrl+Shift+H) | hide; the tray / menu bar icon brings it back |

Each log is titled from the transcript's own words (its most prominent phrases, e.g. "staging rollout, IAM
change, platform team"): keyword extraction done locally, not a summary. The file name is the start time plus
that title. Nothing is filed or cleared until you press Stop recording: the daemon pausing itself after the
time limit, or a restart, just pauses. Logs are kept until you delete them; the rolling transcript database
behind the live view still expires after 3 days.

### The command line

| Command | |
|---|---|
| `heard resume` / `heard pause` / `heard status` | turn capture on and off; status also says whether the daemon is running |
| `heard --last 3m` | everything from the last 3 minutes (`90s`, `2h`, `1d` work too) |
| `heard budget` | search ([SQLite FTS5 syntax](https://www.sqlite.org/fts5.html#full_text_query_syntax): `"exact phrase"`, `deploy OR release`) |
| `heard --last 10m budget` | search within a time window |
| `heard -f` | follow new lines live; in a terminal, a dimmed line shows the sentence in progress |
| `heard --last 1h > call.txt` | save a window as a text file |

## How it works

`heard-daemon` reads 16 kHz mono audio from two capture processes and cuts each into utterances with a simple
energy gate (a 0.5 s pause ends one; long monologues are cut every 10 s). Finished utterances are transcribed
with voice-activity filtering and stored. While someone is still talking, the utterance so far is re-transcribed
about once a second into `live.json`, so `heard -f` and the overlay can show live captions.

The capture processes are `parec` on Linux, `heard-tap` on macOS (`macos/heard-tap.swift`, ~300 lines of Swift
over Core Audio) and the daemon itself in `tap` mode on Windows (PyAudioWPatch, whose PortAudio build exposes
a loopback input for every output device). Each one writes raw PCM to its stdout. A watcher beside each capture
re-checks the default device every few seconds (ten on Windows) and restarts the capture when you switch between
speakers and headphones, and ends it the moment Listening is turned off. While paused, nothing runs.

`heard-ui` is one PySide6 (Qt) script for all three platforms, and runs once per user (a second start exits). It polls the database, `live.json`, the pause
flag and the daemon's heartbeat file; the only platform-specific parts are the floating non-activating window,
the global hotkeys (Carbon on macOS, `RegisterHotKey` on Windows) and the screen-capture exclusion
(`NSWindow.sharingType` on macOS, `SetWindowDisplayAffinity` on Windows).

On Linux the daemon holds a systemd-logind *delay* inhibitor and exits just before suspend. systemd restarts it
after resume with a fresh CUDA context. Keeping a CUDA context across suspend/resume once faulted the NVIDIA
driver into "reboot required". On macOS and Windows a capture process that fails (sleep, an unplugged headset)
is restarted on whatever the default device is then. Only one daemon runs per user: a second one exits.

Environment overrides: `HEARD_MODEL`, `HEARD_CPU_MODEL`, `HEARD_CPU_THREADS`, `HEARD_RETENTION_DAYS`,
`HEARD_MAX_LISTEN_MINUTES`, `HEARD_START_LISTENING` (capture from boot instead of starting paused),
`HEARD_THEM_SOURCE` (a fixed source instead of following the default output: a PulseAudio source name, a
macOS device UID from `heard-tap list`, or a Windows device name), `HEARD_ME_SOURCE`.

## Consent

This transcribes other people's speech. Many places, including California, require everyone's consent to record
a confidential conversation, and a transcript likely counts. Tell people, follow your employer's policy, and
leave Listening off when in doubt.

## License

MIT
