#!/bin/zsh
# Install LogicProMCPHost: the launchd-started process that alone holds Accessibility.
#
#   Scripts/install-host.sh              build release, assemble the app, sign, (re)load the agent
#   Scripts/install-host.sh --no-agent   build, assemble and sign, then start the host once with
#                                        `open` (nothing starts at login; quit it with --stop)
#   Scripts/install-host.sh --stop       stop a host started with --no-agent
#   Scripts/install-host.sh --uninstall  unload the agent and remove the app and the plist
#
# Signing. macOS ties a TCC grant to the code's designated requirement. An ad-hoc signature's
# requirement is its own hash, so every rebuild needs the grant again. Set
# LOGIC_MCP_SIGN_IDENTITY to a code-signing certificate in your keychain (a self-signed one from
# Keychain Access > Certificate Assistant works) and the requirement becomes identifier +
# certificate, which survives rebuilds.
#
# Afterwards: System Settings > Privacy & Security > Accessibility > enable "LogicProMCPHost".
# Clients connect through tools/mcp-socket-relay; they need no Accessibility of their own.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/LogicProMCPHost.app"
LABEL="com.logicpro.mcp.host"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
IDENTITY="${LOGIC_MCP_SIGN_IDENTITY:--}"
DOMAIN="gui/$(id -u)"

unload() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

MODE="${1:-agent}"
if [[ "$MODE" == "--stop" ]]; then
  pkill -f "$APP/Contents/MacOS/LogicProMCPHost" && echo "stopped" || echo "not running"
  exit 0
fi

if [[ "$MODE" == "--uninstall" ]]; then
  unload
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "uninstalled $LABEL"
  exit 0
fi

[[ -f "$HOME/.swiftly/env.sh" ]] && . "$HOME/.swiftly/env.sh"
(cd "$REPO" && swift build -c release --product LogicProMCP && swift build -c release --product LogicProMCPHost)
BIN="$REPO/.build/release"

unload
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/LogicProMCPHost" "$APP/Contents/MacOS/LogicProMCPHost"
cp "$BIN/LogicProMCP" "$APP/Contents/MacOS/LogicProMCP"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleName</key><string>LogicProMCPHost</string>
    <key>CFBundleExecutable</key><string>LogicProMCPHost</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Logic Pro MCP controls Logic Pro for the tools you call.</string>
</dict>
</plist>
EOF
# Hardened runtime: launch-time DYLD_* variables are ignored, so nobody who (re)starts the host can
# load code into the process that holds Accessibility. Its one entitlement keeps Apple Events.
ENTITLEMENTS="$REPO/Scripts/LogicProMCPHost.entitlements"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" \
  --identifier com.logicpro.mcp.server "$APP/Contents/MacOS/LogicProMCP"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" \
  --identifier "$LABEL" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$HOME/Library/Logs/LogicProMCP"
if [[ "$MODE" == "--no-agent" ]]; then
  pkill -f "$APP/Contents/MacOS/LogicProMCPHost" 2>/dev/null || true
  open -g -a "$APP" --stderr "$HOME/Library/Logs/LogicProMCP/host.log"
  echo "started $APP once (signed with: $IDENTITY); nothing starts at login"
  sleep 1
  "$APP/Contents/MacOS/LogicProMCPHost" --check
  exit 0
fi
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/LogicProMCPHost</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/LogicProMCP/host.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $APP (signed with: $IDENTITY)"
echo "agent: $LABEL; log: ~/Library/Logs/LogicProMCP/host.log; socket: ~/Library/Application Support/LogicProMCP/mcp.sock"
"$APP/Contents/MacOS/LogicProMCPHost" --check
