#!/bin/sh
# Build heard-tap, install heard, heard-daemon and heard-tap into ~/.local/bin, and start the
# launchd user agent. Re-run after pulling changes. `macos/install.sh --no-agent` only installs.
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

install -m 755 heard heard-daemon build/heard-tap "$HOME/.local/bin/"
sed "s|__HOME__|$HOME|g" launchd/local.heard.plist > "$HOME/Library/LaunchAgents/local.heard.plist"
echo "installed heard, heard-daemon and heard-tap in ~/.local/bin"

if [ "${1:-}" = "--no-agent" ]; then
    exit 0
fi
launchctl bootout "gui/$(id -u)/local.heard" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.heard.plist"
cat <<EOF
heard is running as a launchd agent (local.heard).
  log:       tail -f ~/Library/Logs/heard.log   (the first start downloads the model)
  restart:   launchctl kickstart -k gui/$(id -u)/local.heard
  uninstall: launchctl bootout gui/$(id -u)/local.heard
Grant the two prompts (Microphone, System Audio Recording) when they appear.
EOF
