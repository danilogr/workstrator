#!/usr/bin/env bash
# Uninstall the workstrator LaunchAgent
set -euo pipefail

LABEL="com.appliedmindai.workstrator"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

# Stop and unload
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Remove plist
rm -f "$PLIST_PATH"

echo "Workstrator uninstalled."
echo "  Logs are still at: $(cd "$(dirname "$0")" && pwd)/logs/"
