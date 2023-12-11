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
$OTEL_VERSION = "0.90.1"

# architecture check
$ARCH = if ($ARCH -eq "amd64") { "amd64" } elseif ($ARCH -eq "arm64") { "arm64" } elseif ($ARCH -eq "x86") { "386" } else { $ARCH }

# Construct the download URL for otel-collector based on OS and architecture
# $DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

$DOWNLOAD_URL = "https://zinc-public-data.s3.us-west-2.amazonaws.com/opentelemetry-collector-releases/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.zip

# Download otel-collector from the specified URL
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile "otelcol-contrib.zip"

# Ensure the target directory for extraction exists
$directoryPath = "C:\otel-collector\"
if (-not (Test-Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory
}

# Extract the downloaded archive to the target directory
# tar -xzf "otelcol-contrib.tar.gz" -C $directoryPath
Expand-Archive "otelcol-contrib.tar.gz" -DestinationPath $directoryPath

# Generate a sample configuration file for otel-collector
$ConfigContent = @"
receivers:
  hostmetrics:
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
      
  windowsperfcounters/memory:
    metrics:
      bytes.committed:
        description: the number of bytes committed to memory
        unit: By
        gauge:
    collection_interval: 30s
    perfcounters:
      - object: Memory
        counters:
          - name: Committed Bytes
            metric: bytes.committed

  windowsperfcounters/processor:
    collection_interval: 1m
    metrics:
      processor.time:
        description: active and idle time of the processor
        unit: "%"
        gauge:
    perfcounters:
      - object: "Processor"
        instances: "*"
        counters:
          - name: "% Processor Time"
            metric: processor.time
            attributes:
              state: active
      - object: "Processor"
        instances: [1, 2]
        counters:
          - name: "% Idle Time"
            metric: processor.time
            attributes:
              state: idle
  windowseventlog/application:
    channel: application
  windowseventlog/security:
    channel: security
  windowseventlog/setup:
    channel: setup
  windowseventlog/system:
    channel: system
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
      receivers: [windowsperfcounters/processor, windowsperfcounters/memory, hostmetrics]
      processors: [ memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [windowseventlog/application,windowseventlog/security,windowseventlog/setup,windowseventlog/system]
      processors: [ memory_limiter, batch]
      exporters: [otlphttp/openobserve]
"@

# Write the configuration content to a file
$ConfigContent | Out-File "${directoryPath}otel-config.yaml"

# Define the service parameters
$serviceName = "otel-collector"
$params = @{
  Name           = $serviceName
  BinaryPathName = "${directoryPath}otelcol-contrib.exe --config=${directoryPath}otel-config.yaml"
  DisplayName    = $serviceName
  StartupType    = "Automatic"
  Description    = "OpenObserve otel-collector service."
}

# Create the service
New-Service @params
