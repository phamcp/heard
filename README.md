# heard

A local, real-time transcript of everything you hear and say on your desktop, so you can search for what
someone said three minutes ago, whichever app it came from. Linux, macOS and Windows.

```
$ heard --last 3m
Mon 10:08:26  them: I think the staging rollout is blocked on the IAM change.
Mon 10:08:36    me: Okay, I'll ping the platform team after this.
$ heard "staging rollout"
$ heard -f          # follow live, with an in-progress line for whoever is talking right now
```

- **Any app:** Zoom, Slack huddles, Google Meet, a browser video. It records the system's default output, not
  a particular app.
- **Both sides:** "them" is everything played to your default output; "me" is your default microphone.
- **Local only:** audio never leaves the machine and is never written to disk. Speech is transcribed by
  [faster-whisper](https://github.com/SYSTRAN/faster-whisper) on your GPU (or CPU) and only the text is stored
  in a SQLite full-text index under `~/.local/share/heard/`. Lines older than 7 days are deleted.
- **Read-only capture:** it never loads modules, moves streams, or installs a virtual audio device, so it is
  safe to start in the middle of a call. Per platform:
  - Linux: `parec` on the output's monitor source and on the microphone (PulseAudio or PipeWire)
  - macOS: a [Core Audio process tap](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
    on the default output (macOS 14.2+), and the default input device
  - Windows: the WASAPI loopback of the default output, and the default microphone

This fork adds the macOS and Windows ports to [ZachGoldberg/heard](https://github.com/ZachGoldberg/heard).

## Requirements

- [uv](https://docs.astral.sh/uv/). `heard-daemon` is a uv script and installs its own dependencies on the first
  run (faster-whisper, numpy; on Linux and Windows also NVIDIA's pip-packaged cuBLAS/cuDNN; on Windows
  sounddevice).
- Optional: an NVIDIA GPU (Linux, Windows). The default model is `large-v3-turbo` on CUDA. Without a usable
  GPU it falls back to `small.en` on the CPU automatically. macOS always uses the CPU (`small.en` by default;
  set `HEARD_MODEL` to try a bigger one on Apple silicon).
- Linux: PulseAudio, or PipeWire with `pipewire-pulse` (`parec`, `pactl`); a systemd user session (optional,
  for running it in the background)
- macOS: 14.2 or newer, and the Xcode Command Line Tools (`xcode-select --install`) to build the small
  `heard-tap` helper
- Windows: 10 or 11

## Install

### Linux

```sh
git clone https://github.com/phamcp/heard
install -m 755 heard/heard heard/heard-daemon ~/.local/bin/
install -m 644 heard/systemd/heard.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now heard.service
journalctl --user -u heard -f      # first start downloads the model (~1.5 GB for large-v3-turbo)
```

### macOS

```sh
git clone https://github.com/phamcp/heard
heard/macos/install.sh             # builds heard-tap, installs to ~/.local/bin, starts the launchd agent
tail -f ~/Library/Logs/heard.log   # first start downloads the model (~500 MB for small.en)
```

The first start asks for two permissions, which go to `heard-tap`: **Microphone**, and **System Audio
Recording** (System Settings → Privacy & Security → Screen & System Audio Recording, "System Audio Recording
Only"). Until both are granted the daemon runs but hears silence. Re-run `macos/install.sh` after pulling
changes; a rebuilt `heard-tap` asks for the permissions again.

`launchctl kickstart -k gui/$UID/local.heard` restarts it, `launchctl bootout gui/$UID/local.heard` stops and
uninstalls the agent. `macos/install.sh --no-agent` only installs the files, for running `heard-daemon` by hand.

### Windows

```powershell
git clone https://github.com/phamcp/heard
powershell -ExecutionPolicy Bypass -File heard\windows\install.ps1   # installs to %USERPROFILE%\.local\bin, registers a logon task
Get-Content -Wait $env:USERPROFILE\.local\share\heard\heard.log     # first start downloads the model
```

The task "heard" starts the daemon (hidden) at logon and restarts it if it stops; `Stop-ScheduledTask heard`
and `Start-ScheduledTask heard` control it, `Unregister-ScheduledTask heard` removes it. `windows\install.ps1
-NoTask` only installs the files; then `uv run --script heard-daemon` runs it in a terminal.

## Usage

| Command | |
|---|---|
| `heard --last 3m` | everything from the last 3 minutes (`90s`, `2h`, `1d` work too) |
| `heard budget` | search ([SQLite FTS5 syntax](https://www.sqlite.org/fts5.html#full_text_query_syntax): `"exact phrase"`, `deploy OR release`) |
| `heard --last 10m budget` | search within a time window |
| `heard -f` | follow new lines live; in a terminal, a dimmed line shows the sentence in progress |
| `heard pause` / `heard resume` / `heard status` | stop and restart capture (e.g. for calls you shouldn't record) |

## How it works

`heard-daemon` reads 16 kHz mono audio from two capture processes and cuts each into utterances with a simple
energy gate (a 0.5 s pause ends one; long monologues are cut every 10 s). Finished utterances are transcribed
with voice-activity filtering and stored. While someone is still talking, the utterance so far is re-transcribed
about once a second into `live.json`, so `heard -f` can show live captions. Finished lines always take priority.

The capture processes are `parec` on Linux, `heard-tap` on macOS (`macos/heard-tap.swift`, ~300 lines of Swift
over Core Audio) and the daemon itself in `tap` mode on Windows (sounddevice / PortAudio). Each one writes raw
PCM to its stdout; the daemon re-checks the default output every few seconds and restarts the capture when you
switch between speakers and headphones.

On Linux it holds a systemd-logind *delay* inhibitor and exits just before suspend. systemd restarts it after
resume with a fresh CUDA context. Keeping a CUDA context across suspend/resume once faulted the NVIDIA driver
into "reboot required". On macOS and Windows the capture process exits when its device goes quiet (sleep, an
unplugged headset) and is restarted on whatever the default device is then.

Environment overrides: `HEARD_MODEL`, `HEARD_CPU_MODEL`, `HEARD_CPU_THREADS`, `HEARD_RETENTION_DAYS`,
`HEARD_THEM_SOURCE` (a fixed source instead of following the default output: a PulseAudio source name, a
macOS device UID from `heard-tap list`, or a Windows device name), `HEARD_ME_SOURCE`.

## Consent

This transcribes other people's speech. Many places, including California, require everyone's consent to record
a confidential conversation, and a transcript likely counts. Tell people, follow your employer's policy, and use
`heard pause` when in doubt.

## License

MIT
