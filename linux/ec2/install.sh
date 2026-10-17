#!/bin/bash
set -euo pipefail

# Deprecated: kept only so existing install commands that point here keep working.
# linux/install.sh now auto-detects EC2, GCP and Azure; this downloads and runs it.

SCRIPT_URL="https://raw.githubusercontent.com/openobserve/agents/main/linux/install.sh"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if ! curl -fsSL "$SCRIPT_URL" -o "$WORKDIR/install.sh"; then
    echo "ERROR: Failed to download $SCRIPT_URL" >&2
    exit 1
fi

bash "$WORKDIR/install.sh" "$@"
