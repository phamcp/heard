#!/bin/sh
# Build heard-tap, install heard, heard-daemon, heard-ui and heard-tap into ~/.local/bin, and start the
# two launchd user agents (daemon, overlay). Re-run after pulling changes. `--no-agent` only installs.
set -eu
cd "$(dirname "$0")/.."

if ! command -v swiftc >/dev/null; then
    echo "swiftc not found: install the Xcode Command Line Tools first (xcode-select --install)" >&2
    exit 1
fi
if ! command -v uv >/dev/null; then
    echo "uv not found: brew install uv (or see https://docs.astral.sh/uv/)" >&2
    exit 1
fi

mkdir -p build "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
echo "building heard-tap"
swiftc -O -suppress-warnings -swift-version 5 -target "$(uname -m)-apple-macos14.2" \
    -framework CoreAudio -framework AVFoundation \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker macos/Info.plist \
    -o build/heard-tap macos/heard-tap.swift
codesign --force --sign - build/heard-tap

install -m 755 heard heard-daemon heard-ui build/heard-tap "$HOME/.local/bin/"
for agent in local.heard local.heard-ui; do
    sed "s|__HOME__|$HOME|g" "launchd/$agent.plist" > "$HOME/Library/LaunchAgents/$agent.plist"
done
echo "installed heard, heard-daemon, heard-ui and heard-tap in ~/.local/bin"

if [ "${1:-}" = "--no-agent" ]; then
    exit 0
fi
for agent in local.heard local.heard-ui; do
    launchctl bootout "gui/$(id -u)/$agent" 2>/dev/null || true
    for attempt in 1 2 3 4 5; do   # right after a bootout, launchd can still be tearing the old job down
        sleep 1
        if launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$agent.plist" 2>/dev/null; then
            break
        fi
        [ "$attempt" = 5 ] && { echo "could not start $agent; try: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$agent.plist" >&2; exit 1; }
    done
done
cat <<EOF
heard is running: the daemon (local.heard, started paused) and the overlay (local.heard-ui).
  logs:      ~/Library/Logs/heard.log  ~/Library/Logs/heard-ui.log   (the first start downloads the model)
  restart:   launchctl kickstart -k gui/$(id -u)/local.heard
  uninstall: launchctl bootout gui/$(id -u)/local.heard; launchctl bootout gui/$(id -u)/local.heard-ui
Nothing is captured until you turn Listening on (overlay, ⌘⇧L, or 'heard resume').
Grant the two prompts (Microphone, System Audio Recording) when they appear.
EOF
