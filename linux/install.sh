#!/bin/bash
set -euo pipefail

# Check if the required number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <URL> <Authorization_Key>"
    exit 1
fi

URL=$1
AUTH_KEY=$2

# Ensure the 'openobserve-agent' group and user exist.
# Create the group first, then the user with it as the primary group, instead of
# relying on useradd's implicit group creation and a separate groupadd check.
if ! getent group openobserve-agent >/dev/null; then
    groupadd --system openobserve-agent
fi

if ! id -u openobserve-agent &>/dev/null; then
    useradd --system --gid openobserve-agent openobserve-agent
fi

# Grant log-read access on every run (not just first-time creation) so existing
# installs get corrected too.
usermod -aG systemd-journal openobserve-agent            # read journald logs
if getent group adm >/dev/null; then
    usermod -aG adm openobserve-agent                    # read /var/log files owned by root:adm
fi

# Detect OS and architecture
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
OTEL_VERSION="0.156.0"

case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

# Construct the download URL
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

# Download and install the binary inside a temp workdir that is always cleaned up,
# with a hard failure on any download or extraction error.
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading $DOWNLOAD_URL"
if ! curl -fL "$DOWNLOAD_URL" -o "$WORKDIR/otelcol-contrib.tar.gz"; then
    echo "ERROR: Failed to download otel-collector from $DOWNLOAD_URL" >&2
    exit 1
fi

# Sanity check: make sure we got a real archive, not an empty or error response.
if [ ! -s "$WORKDIR/otelcol-contrib.tar.gz" ] || [ "$(stat -c%s "$WORKDIR/otelcol-contrib.tar.gz")" -lt 1024 ]; then
    echo "ERROR: Downloaded archive is missing or too small. Aborting." >&2
    exit 1
fi

tar -xzf "$WORKDIR/otelcol-contrib.tar.gz" -C "$WORKDIR"
install -m 0755 "$WORKDIR/otelcol-contrib" /usr/local/bin/otelcol-contrib

# Generate a sample configuration file
cat > /etc/otel-config.yaml <<EOL
receivers:
  journald:
    directory: /var/log/journal
  filelog/std:
    include: [ /var/log/**log ]
    # start_at: beginning
  hostmetrics:
    root_path: /
    collection_interval: 30s
    scrapers:
      cpu:
      disk:
      filesystem:
      load:
      memory:
      network:
      paging:          
      processes:
      # process: # a bug in the process scraper causes the collector to throw errors so disabling it for now
processors:
  resourcedetection/system:
    detectors: ["system"]
    system:
      hostname_sources: ["os"]
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 15
  batch:
    send_batch_size: 10000
    timeout: 10s

extensions:
  zpages: {}

exporters:
  otlphttp/openobserve:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
  otlphttp/openobserve_journald:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
      stream-name: journald

service:
  extensions: [zpages]
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [filelog/std]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs/journald:
      receivers: [journald]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve_journald]
EOL

# Set up otel-collector to run as a systemd service
cat > /etc/systemd/system/otel-collector.service <<EOL
[Unit]
Description=OpenTelemetry Collector
After=network.target network-online.target

[Service]
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/otel-config.yaml
Restart=always
RestartSec=10
User=openobserve-agent
Group=openobserve-agent

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and (re)start the service. Use restart so re-runs pick up the
# new binary/config instead of no-op'ing when it is already running.
systemctl daemon-reload
systemctl enable otel-collector
systemctl restart otel-collector

# Verify the service actually came up instead of unconditionally reporting success.
if systemctl is-active --quiet otel-collector; then
    echo "Otel-collector service started!"
else
    echo "ERROR: otel-collector failed to start. Inspect logs with: journalctl -u otel-collector -n 50" >&2
    exit 1
fi
