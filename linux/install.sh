#!/bin/bash

# Check if the required number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <URL> <Authorization_Key>"
    exit 1
fi

URL=$1
AUTH_KEY=$2

# Ensure 'openobserve-agent' user and group exist
if ! id -u openobserve-agent &>/dev/null; then
    useradd --system openobserve-agent
fi

if ! grep -q "^openobserve-agent:" /etc/group; then
    groupadd openobserve-agent
fi

# Detect OS and architecture
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
OTEL_VERSION="0.88.0"

if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Construct the download URL
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

# Download the otel-collector binary
curl -L $DOWNLOAD_URL -o otelcol-contrib.tar.gz

# Extract the binary
tar -xzf otelcol-contrib.tar.gz

# Move the binary to /usr/local/bin
mv otelcol-contrib /usr/local/bin/

# Generate a sample configuration file
cat > /etc/otel-config.yaml <<EOL
receivers:
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
  resourcedetection:
    detectors: [system]
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 15
  batch:
    send_batch_size: 10000
    timeout: 10s

extensions:
  zpages: {}
  memory_ballast:
    size_mib: 512

exporters:
  otlphttp/openobserve:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"

service:
  extensions: [zpages, memory_ballast]
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [ memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [filelog/std]
      processors: [ memory_limiter, batch]
      exporters: [otlphttp/openobserve]
EOL

# Set up otel-collector to run as a systemd service
cat > /etc/systemd/system/otel-collector.service <<EOL
[Unit]
Description=OpenTelemetry Collector
After=network.target

[Service]
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/otel-config.yaml
Restart=always
User=openobserve-agent
Group=openobserve-agent

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable otel-collector service
systemctl daemon-reload
systemctl enable otel-collector
systemctl start otel-collector

echo "Otel-collector service started!"
