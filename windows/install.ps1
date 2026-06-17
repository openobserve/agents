# Define the script parameters
param (
    [string]$URL,
    [string]$AUTH_KEY
)

# Validate the provided parameters
if (-not $URL -or -not $AUTH_KEY) {
    Write-Host "Usage: .\install.ps1 -URL <URL> -AUTH_KEY <Authorization_Key>"
    exit 1
}

# Detect the operating system and its architecture
$OS = "windows"
$ARCH = $ENV:PROCESSOR_ARCHITECTURE.ToLower()
$OTEL_VERSION = "0.128.0"

# architecture check
$ARCH = if ($ARCH -eq "amd64") { "amd64" } elseif ($ARCH -eq "arm64") { "arm64" } elseif ($ARCH -eq "x86") { "386" } else { $ARCH }

# Construct the download URL for otel-collector based on OS and architecture
# $DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

$DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

# Download otel-collector from the specified URL
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile "otelcol-contrib.tar.gz"

# Ensure the target directory for extraction exists
$SERVICE_NAME="otel-collector"
$directoryPath = "C:\${SERVICE_NAME}\"
if (-not (Test-Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory
}

# Extract the downloaded archive to the target directory
# tar -xzf "otelcol-contrib.tar.gz" -C $directoryPath
# Expand-Archive "otelcol-contrib.zip" -DestinationPath $directoryPath -Force
tar -xvzf "otelcol-contrib.tar.gz" -C $directoryPath


# Generate a sample configuration file for otel-collector
$ConfigContent = @"
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
          system.cpu.logical.count:
            enabled: true
      disk:
      filesystem:
        metrics:
          system.filesystem.utilization:
            enabled: true
      load:
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      network:
      paging:
      processes:
      process:
        metrics:
          process.cpu.utilization:
            enabled: true
          process.memory.utilization:
            enabled: true

  windowsperfcounters/memory:
    collection_interval: 30s
    metrics:
      bytes.committed:
        description: Number of bytes committed to memory
        unit: By
        gauge:
    perfcounters:
      - object: "Memory"
        counters:
          - name: "Committed Bytes"
            metric: bytes.committed

  windowsperfcounters/processor:
    collection_interval: 1m
    metrics:
      processor.time:
        description: Active vs. idle CPU time
        unit: "%"
        gauge:
    perfcounters:
      - object: "Processor"
        instances: "*"
        counters:
          - name: "% Processor Time"
            metric: processor.time
            attributes: { state: active }
      - object: "Processor"
        instances: ["1", "2"]
        counters:
          - name: "% Idle Time"
            metric: processor.time
            attributes: { state: idle }

  windowseventlog/application: { channel: application }
  windowseventlog/security:    { channel: security }
  windowseventlog/setup:       { channel: setup }
  windowseventlog/system:      { channel: system }

processors:
  resourcedetection:
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
      stream-name: windows
      Authorization: "Basic $AUTH_KEY"

service:
  extensions: [zpages]
  pipelines:
    metrics:
      receivers: [windowsperfcounters/processor,
                  windowsperfcounters/memory,
                  hostmetrics]
      processors: [resourcedetection, memory_limiter, batch]
      exporters: [otlphttp/openobserve]

    logs:
      receivers: [windowseventlog/application,
                  windowseventlog/security,
                  windowseventlog/setup,
                  windowseventlog/system]
      processors: [resourcedetection, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
"@

# Write the configuration content to a file
$ConfigContent | Out-File "${directoryPath}otel-config.yaml"

# Define the service parameters
$params = @{
  Name           = $SERVICE_NAME
  BinaryPathName = "${directoryPath}otelcol-contrib.exe --config=${directoryPath}otel-config.yaml"
  DisplayName    = $SERVICE_NAME
  StartupType    = "Automatic"
  Description    = "OpenObserve otel-collector service."
}

# Create the service
New-Service @params

# Start the service
Start-Service $SERVICE_NAME
