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

OTEL_VERSION="0.90.1"

if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Define the binary download URL and the target download path
BINARY_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_darwin_${ARCH}.tar.gz"
BINARY_OPT="/opt/openobserve-collector"
BINARY_PATH="$BINARY_OPT/otelcol-contrib"
PLIST_PATH="/Library/LaunchDaemons/ai.openobserve.otelcol-contrib.plist"
PLIST_NAME="ai.openobserve.otelcol-contrib"

# Check if root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Create directory for binary if it doesn't exist
mkdir -p $(dirname "$BINARY_PATH")

# Download the otel-collector binary
cd $BINARY_OPT && curl -L $BINARY_URL | tar -xz

# make the binary executable
chmod +x $BINARY_PATH

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
      # cpu: not implemented on mac (no cgo)
      # disk: not implemented on mac (no cgo)
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
    <key>ProgramArguments</key>
    <array>
	<string>/opt/openobserve-collector/otelcol-contrib</string>
	<string>--config</string>
	<string>/etc/otel-config.yaml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# unloading if already present
echo "unloading if already present"
launchctl bootout "system/$PLIST_NAME"
# launchctl enable "system/$PLIST_NAME"

# Load the plist into launchd
echo "Setting service to launch during system startup"
launchctl bootstrap system "$PLIST_PATH"

echo "Binary downloaded and set up to run at launch!"
