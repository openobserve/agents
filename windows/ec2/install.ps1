# Define the script parameters
param (
    [string]$URL,
    [string]$AUTH_KEY
)

$ErrorActionPreference = "Stop"

# Validate the provided parameters
if (-not $URL -or -not $AUTH_KEY) {
    Write-Host "Usage: .\install.ps1 -URL <URL> -AUTH_KEY <Authorization_Key>"
    exit 1
}

# GitHub requires TLS 1.2; older Windows/Server defaults to TLS 1.0 and fails the TLS handshake
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Detect the operating system and its architecture
$OS = "windows"
$ARCH = $ENV:PROCESSOR_ARCHITECTURE.ToLower()
$OTEL_VERSION = "0.111.0"

# Architecture check
$ARCH = if ($ARCH -eq "amd64") { "amd64" } elseif ($ARCH -eq "arm64") { "arm64" } elseif ($ARCH -eq "x86") { "386" } else { $ARCH }

# OpenTelemetry collector publishes Windows assets ONLY as .tar.gz (no .zip), so download that
$DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

$ARCHIVE = "otelcol-contrib.tar.gz"

# Download otel-collector from the specified URL
$ProgressPreference = 'SilentlyContinue'
Write-Host "Downloading $DOWNLOAD_URL"
try {
    Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile $ARCHIVE -UseBasicParsing
} catch {
    Write-Host "ERROR: Failed to download otel-collector from $DOWNLOAD_URL"
    Write-Host $_.Exception.Message
    exit 1
}

# Sanity check: make sure we actually got a real archive and not an empty/HTML error page
if (-not (Test-Path $ARCHIVE) -or (Get-Item $ARCHIVE).Length -lt 1024) {
    Write-Host "ERROR: Downloaded archive is missing or too small. Aborting."
    exit 1
}

# Ensure the target directory for extraction exists
$SERVICE_NAME = "otel-collector"
$directoryPath = "C:\${SERVICE_NAME}\"
if (-not (Test-Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory | Out-Null
}

# Extract using tar (built into Windows 10 1803+ and Server 2019+)
Write-Host "Extracting to $directoryPath"
tar -xzf $ARCHIVE -C $directoryPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: tar extraction failed (exit code $LASTEXITCODE)."
    exit 1
}

# Verify the binary landed where we expect
$binaryPath = "${directoryPath}otelcol-contrib.exe"
if (-not (Test-Path $binaryPath)) {
    Write-Host "ERROR: $binaryPath not found after extraction. Aborting."
    exit 1
}

# Generate configuration file for otel-collector
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
      # process: # can cause errors on some Windows configurations, disabled by default

  windowsperfcounters/processor:
    collection_interval: 30s
    metrics:
      processor.time:
        description: Active and idle time of the processor
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

  windowsperfcounters/memory:
    collection_interval: 30s
    metrics:
      bytes.committed:
        description: Number of bytes committed to memory
        unit: By
        gauge:
    perfcounters:
      - object: Memory
        counters:
          - name: Committed Bytes
            metric: bytes.committed

  windowseventlog/application:
    channel: application
  windowseventlog/security:
    channel: security
  windowseventlog/setup:
    channel: setup
  windowseventlog/system:
    channel: system

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
      stream-name: windows

service:
  extensions: [zpages]
  pipelines:
    metrics:
      receivers: [hostmetrics, windowsperfcounters/processor, windowsperfcounters/memory]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [windowseventlog/application, windowseventlog/security, windowseventlog/setup, windowseventlog/system]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
"@

# Write the configuration content to a file (UTF-8 without BOM so the collector parses YAML cleanly)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("${directoryPath}otel-config.yaml", $ConfigContent, $utf8NoBom)

# Remove any prior install of the service so re-runs don't fail
if (Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue) {
    Write-Host "Existing service found, removing it first."
    Stop-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    sc.exe delete $SERVICE_NAME | Out-Null
    Start-Sleep -Seconds 2
}

# Define the service parameters
$params = @{
    Name           = $SERVICE_NAME
    BinaryPathName = "${binaryPath} --config=${directoryPath}otel-config.yaml"
    DisplayName    = $SERVICE_NAME
    StartupType    = "Automatic"
    Description    = "OpenObserve otel-collector service."
}

# Create the service
New-Service @params

# Start the service
Start-Service $SERVICE_NAME

# Report the real state instead of assuming success
$svc = Get-Service $SERVICE_NAME
if ($svc.Status -eq "Running") {
    Write-Host "Otel-collector service started successfully!"
} else {
    Write-Host "Otel-collector service is in state: $($svc.Status). Check C:\${SERVICE_NAME}\ and Event Viewer for details."
    exit 1
}
