#!/usr/bin/env bash
# Install the workstrator as a macOS LaunchAgent (runs forever, auto-restarts)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.appliedmindai.workstrator"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$PLIST_DIR" "$LOG_DIR"

# Collect PATH from current shell so launchd can find claude, gh, python3, git
CURRENT_PATH=$(bash -lc 'echo $PATH')

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/workstrator.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>60</integer>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd-stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$CURRENT_PATH</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
</dict>
</plist>
EOF

echo "Plist written to $PLIST_PATH"

# Unload first if already loaded (ignore errors)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Wait for old process to fully exit and launchd to settle
sleep 5

# Clean stale lock
rm -rf "$SCRIPT_DIR/.lock"

# Load the service
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Workstrator installed and running."
echo "  Logs:    $LOG_DIR/"
echo "  Status:  launchctl print gui/$(id -u)/$LABEL"
echo "  Stop:    bash $SCRIPT_DIR/uninstall.sh"
