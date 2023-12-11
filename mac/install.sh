#!/bin/bash

OTEL_VERSION="0.88.0"

if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Define the binary download URL and the target download path
BINARY_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_darwin_${ARCH}.tar.gz"
BINARY_PATH="/opt/openobserve-collector/otelcol-contrib"
PLIST_PATH="/Library/LaunchDaemons/ai.openobserve.otelcol-contrib.plist"

# Check if root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Create directory for binary if it doesn't exist
mkdir -p $(dirname "$BINARY_PATH")

# Download the binary
curl -L "$BINARY_URL" -o "$BINARY_PATH"

# Make the binary executable
chmod +x "$BINARY_PATH"

# Generate a sample configuration file
cat > /etc/otel-config.yaml <<EOL
receivers:
  filelog/std:
    include: [ /var/log/**log ]
    include_file_name: false
    include_file_path: true
  hostmetrics:
    collection_interval: 30s
    scrapers:
      # cpu: not implemented on mac
      # disk: not implemented on mac
      filesystem:
      load:
      memory:
      network:
      paging:          
      processes:
      process: 
processors:
  resourcedetection/system:
    detectors: [ "system" ]
    system:
      hostname_sources: [ "os" ]
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
      stream-name: mac
      Authorization: "Basic $AUTH_KEY"

service:
  extensions: [zpages, memory_ballast]
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [filelog/std]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]

EOL


# Save the plist content to the target plist path
cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.openobserve.otelcol-contrib</string>
    <key>Program</key>
    <string>/opt/openobserve-collector/otelcol-contrib</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# Load the plist into launchd
launchctl bootstrap system "$PLIST_PATH"

echo "Binary downloaded and set up to run at launch!"
