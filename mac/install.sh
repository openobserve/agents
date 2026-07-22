#!/bin/bash

# Installs the OpenTelemetry collector on macOS as a LaunchDaemon, along with a
# second daemon that bridges the macOS unified log into the collector.
#
# Two launchd services are installed:
#   ai.openobserve.otelcol-contrib   - the collector itself
#   ai.openobserve.macos-unified-log - `log stream --style ndjson | nc` bridge

set -e

# Check if the required number of arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <URL> <Authorization_Key>"
    exit 1
fi

URL=$1
AUTH_KEY=$2

# Check if root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# This script installs a darwin binary and launchd services, so guard the platform
if [ "$(uname)" != "Darwin" ]; then
    echo "This script is for macOS. For Linux see linux/install.sh"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
OTEL_VERSION="0.156.0"

if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

# Define the binary download URL and the target paths
BINARY_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_darwin_${ARCH}.tar.gz"
BINARY_OPT="/opt/openobserve-collector"
BINARY_PATH="$BINARY_OPT/otelcol-contrib"
CONFIG_PATH="/etc/otel-config.yaml"
BRIDGE_PATH="$BINARY_OPT/macos-unified-log.sh"
LOG_DIR="/Library/Logs/openobserve-collector"

PLIST_NAME="ai.openobserve.otelcol-contrib"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}.plist"
BRIDGE_PLIST_NAME="ai.openobserve.macos-unified-log"
BRIDGE_PLIST_PATH="/Library/LaunchDaemons/${BRIDGE_PLIST_NAME}.plist"

# Port the collector listens on for the unified log bridge. Bound to loopback only.
TCP_PORT="54525"

# Create directories
mkdir -p "$BINARY_OPT"
mkdir -p "$LOG_DIR"

# Download the otel-collector binary
echo "Downloading $BINARY_URL"
cd "$BINARY_OPT"
if ! curl -fL "$BINARY_URL" -o otelcol-contrib.tar.gz; then
    echo "ERROR: Failed to download otel-collector from $BINARY_URL"
    exit 1
fi

# Sanity check: make sure we got a real archive and not an empty or error response
if [ ! -s otelcol-contrib.tar.gz ] || [ "$(stat -f%z otelcol-contrib.tar.gz)" -lt 1024 ]; then
    echo "ERROR: Downloaded archive is missing or too small. Aborting."
    exit 1
fi

tar -xzf otelcol-contrib.tar.gz
rm -f otelcol-contrib.tar.gz

# Verify the binary landed where we expect
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: $BINARY_PATH not found after extraction. Aborting."
    exit 1
fi

# Make the binary executable
chmod +x "$BINARY_PATH"

# Generate the configuration file
cat > "$CONFIG_PATH" <<EOL
receivers:
  # Log files in the standard macOS locations. '**' also matches zero directories,
  # so /var/log/**/*.log picks up /var/log/system.log as well as nested files.
  file_log/std:
    include:
      - /var/log/**/*.log
      - /var/log/*.out
      - /Library/Logs/**/*.log
      - /usr/local/var/log/**/*.log
      - /opt/homebrew/var/log/**/*.log
      # - /Users/*/Library/Logs/**/*.log # per-user app logs, opt-in: noisy and often sensitive
    exclude:
      - ${LOG_DIR}/** # never tail our own logs, that would feed back into itself
      - /var/log/asl/**
      - /var/log/DiagnosticMessages/**
    include_file_name: false
    include_file_path: true
    # start_at: beginning

  # The macOS unified log is not readable as a file, so ${BRIDGE_PATH} runs
  # 'log stream --style ndjson' and pipes it into this receiver over loopback TCP.
  tcp_log/macos:
    listen_address: 127.0.0.1:${TCP_PORT}
    operators:
      - type: json_parser
        timestamp:
          parse_from: attributes.timestamp
          layout: '%Y-%m-%d %H:%M:%S.%f%z'
      # Activity events carry no messageType, so guard the parser to keep it quiet
      - type: severity_parser
        parse_from: attributes.messageType
        if: 'attributes?.messageType != nil'
        mapping:
          debug: Debug
          info:
            - Info
            - Default
          error: Error
          fatal: Fault
      - type: move
        from: attributes.eventMessage
        to: body
        if: 'attributes?.eventMessage != nil'

  host_metrics:
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
      # process: # per-process metrics are expensive and noisy, disabled by default

processors:
  resource_detection/system:
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

exporters:
  otlp_http/openobserve:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
  otlp_http/openobserve_macos:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
      stream-name: macos_unified

service:
  # launchd never rotates StandardErrorPath and holds the file open, so a renaming
  # rotator like newsyslog would not help, the collector would keep writing to the
  # rotated inode. Bound the agent's own logs at the source instead: warn and above,
  # with repeated messages sampled. Without this an unreachable endpoint logs a
  # retry per batch, which measures around 42 MiB per day.
  # Set level to info temporarily when debugging.
  telemetry:
    logs:
      level: warn
      sampling:
        enabled: true
        tick: 60s
        initial: 2
        thereafter: 500
  extensions: [zpages]
  pipelines:
    metrics:
      receivers: [host_metrics]
      processors: [resource_detection/system, memory_limiter, batch]
      exporters: [otlp_http/openobserve]
    logs:
      receivers: [file_log/std]
      processors: [resource_detection/system, memory_limiter, batch]
      exporters: [otlp_http/openobserve]
    logs/macos:
      receivers: [tcp_log/macos]
      processors: [resource_detection/system, memory_limiter, batch]
      exporters: [otlp_http/openobserve_macos]
EOL

# Write the unified log bridge. launchd cannot express a pipeline, so it runs this
# script instead. Escaped '\$' below stay literal, they are evaluated at run time.
cat > "$BRIDGE_PATH" <<EOS
#!/bin/bash

# Bridges the macOS unified log into the collector's tcp_log/macos receiver.
# Managed by launchd as ${BRIDGE_PLIST_NAME}; edit the knobs below and then run
#   sudo launchctl kickstart -k system/${BRIDGE_PLIST_NAME}
# to apply the change.

ADDR="127.0.0.1"
PORT="${TCP_PORT}"

# Which events to stream: default | info | debug. Each step up is a large jump in
# volume, 'default' alone is already in the order of a hundred events per second.
LEVEL="default"

# Optional NSPredicate to cut volume, e.g.
#   PREDICATE='messageType == error OR subsystem BEGINSWITH "com.mycompany"'
PREDICATE=""

# On boot this daemon can win the race against the collector, so wait for the
# receiver to accept connections rather than dying and being restarted by launchd.
until /usr/bin/nc -z "\$ADDR" "\$PORT" 2>/dev/null; do
    sleep 2
done

ARGS=(stream --style ndjson --no-backtrace --level "\$LEVEL")
if [ -n "\$PREDICATE" ]; then
    ARGS+=(--predicate "\$PREDICATE")
fi

# With --predicate, 'log' prints a non-JSON "Filtering the log data using ..."
# header first, so keep only real JSON lines.
/usr/bin/log "\${ARGS[@]}" 2>/dev/null | grep --line-buffered '^{' | /usr/bin/nc "\$ADDR" "\$PORT"
EOS

chmod +x "$BRIDGE_PATH"

# Save the plist for the collector
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_PATH}</string>
        <string>--config</string>
        <string>${CONFIG_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/collector.out</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/collector.err</string>
</dict>
</plist>
EOF

# Save the plist for the unified log bridge
cat > "$BRIDGE_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BRIDGE_PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${BRIDGE_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/unified-log.out</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/unified-log.err</string>
</dict>
</plist>
EOF

# Unload if already present, so re-running the installer works
echo "Unloading existing services if present"
launchctl bootout "system/$BRIDGE_PLIST_NAME" 2>/dev/null || true
launchctl bootout "system/$PLIST_NAME" 2>/dev/null || true

# Load the plists into launchd
echo "Setting services to launch during system startup"
launchctl bootstrap system "$PLIST_PATH"
launchctl bootstrap system "$BRIDGE_PLIST_PATH"

# Report the real state instead of assuming success. The collector only binds the
# bridge port once it has loaded the config cleanly, so that is the real health check,
# a job that is merely loaded may still be crash looping on a bad config.
COLLECTOR_UP=""
for _ in $(seq 1 15); do
    if /usr/bin/nc -z 127.0.0.1 "$TCP_PORT" 2>/dev/null; then
        COLLECTOR_UP=1
        break
    fi
    sleep 1
done

if [ -n "$COLLECTOR_UP" ]; then
    echo "Otel-collector service started!"
else
    echo "ERROR: $PLIST_NAME is not listening on 127.0.0.1:${TCP_PORT}."
    echo "       Check ${LOG_DIR}/collector.err"
    exit 1
fi

if pgrep -f "$BRIDGE_PATH" >/dev/null 2>&1; then
    echo "macOS unified log bridge started!"
else
    echo "ERROR: $BRIDGE_PLIST_NAME is not running. Check ${LOG_DIR}/unified-log.err"
    exit 1
fi

echo ""
echo "Note: the unified log is high volume. To reduce it, set LEVEL or PREDICATE in"
echo "      ${BRIDGE_PATH} and run:"
echo "      sudo launchctl kickstart -k system/${BRIDGE_PLIST_NAME}"
