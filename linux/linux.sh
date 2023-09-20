#!/bin/bash

# Check if the required number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <URL> <Authorization_Key>"
    exit 1
fi

URL=$1
AUTH_KEY=$2

# Detect OS and architecture
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Construct the download URL
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.85.0/otelcol-contrib_0.85.0_${OS}_${ARCH}.tar.gz"

# Download the otel-collector binary
curl -L $DOWNLOAD_URL -o otelcol.tar.gz

# Extract the binary
tar -xzf otelcol.tar.gz

# Assuming otel-collector binary is named 'otelcol' inside the tar
mv otelcol /usr/local/bin/

# Generate a sample configuration file
cat > otel-config.yaml <<EOL
receivers:
  otlp:
    protocols:
      grpc:
      http:
  filelog/std:
    include: [ /var/log/**log ]
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

mv otel-config.yaml /etc/otel-config.yaml

# Set up otel-collector to run as a systemd service
cat > /etc/systemd/system/otel-collector.service <<EOL
[Unit]
Description=OpenTelemetry Collector
After=network.target

[Service]
ExecStart=/usr/local/bin/otelcol --config /etc/otel-config.yaml
Restart=always
User=nobody
Group=nobody

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable otel-collector service
systemctl daemon-reload
systemctl enable otel-collector
systemctl start otel-collector

echo "Otel-collector service started!"
