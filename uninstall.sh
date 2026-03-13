#!/usr/bin/env bash
# Uninstall the workstrator LaunchAgent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config for LAUNCHD_LABEL
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
  source "$SCRIPT_DIR/config.sh"
fi

LABEL="${LAUNCHD_LABEL:-com.workstrator}"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

# Stop and unload
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Remove plist
rm -f "$PLIST_PATH"

echo "Workstrator uninstalled."
echo "  Logs are still at: $SCRIPT_DIR/logs/"
