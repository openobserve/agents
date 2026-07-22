#!/bin/bash

# Removes the OpenTelemetry collector and the macOS unified log bridge.

# Check if root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

BINARY_OPT="/opt/openobserve-collector"
CONFIG_PATH="/etc/otel-config.yaml"
LOG_DIR="/Library/Logs/openobserve-collector"

PLIST_NAME="ai.openobserve.otelcol-contrib"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}.plist"
BRIDGE_PLIST_NAME="ai.openobserve.macos-unified-log"
BRIDGE_PLIST_PATH="/Library/LaunchDaemons/${BRIDGE_PLIST_NAME}.plist"

# Stop both services
launchctl bootout "system/$BRIDGE_PLIST_NAME" 2>/dev/null || true
launchctl bootout "system/$PLIST_NAME" 2>/dev/null || true

# The bridge holds a 'log stream' child, make sure it is gone
pkill -f "$BINARY_OPT/macos-unified-log.sh" 2>/dev/null || true

rm -f "$BRIDGE_PLIST_PATH"
rm -f "$PLIST_PATH"
rm -rf "$BINARY_OPT"
rm -f "$CONFIG_PATH"
rm -rf "$LOG_DIR"

echo "Otel-collector uninstalled successfully!"
