#!/bin/bash

BINARY_OPT="/opt/openobserve-collector"
BINARY_PATH="$BINARY_OPT/otelcol-contrib"
PLIST_PATH="/Library/LaunchDaemons/ai.openobserve.otelcol-contrib.plist"
PLIST_NAME="ai.openobserve.otelcol-contrib"

sudo launchctl bootout "system/$PLIST_NAME"
sudo rm -f "$PLIST_PATH"
sudo rm -rf "$BINARY_OPT"
sudo rm -f /etc/otel-config.yaml


