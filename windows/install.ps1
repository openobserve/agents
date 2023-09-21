param (
    [string]$URL,
    [string]$AUTH_KEY
)

if (-not $URL -or -not $AUTH_KEY) {
    Write-Host "Usage: .\install-otel-collector.ps1 -URL <URL> -AUTH_KEY <Authorization_Key>"
    exit 1
}

# Detect OS and architecture
$OS = "windows"
$ARCH = $ENV:PROCESSOR_ARCHITECTURE.ToLower()

if ($ARCH -eq "amd64") {
    $ARCH = "amd64"
} elseif ($ARCH -eq "arm64") {
    $ARCH = "arm64"
}

# Construct the download URL for otel-collector
$DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.85.0/otelcol-contrib_0.85.0_${OS}_${ARCH}.tar.gz"

# Download the otel-collector binary
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile "otelcol-contrib.tar.gz"

# Extract the binary
tar -xzf "otelcol-contrib.tar.gz" -C "C:\Program Files\otel-collector\"

# Generate a sample configuration file
$ConfigContent = @"
receivers:
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
  windowseventlog:
        channel: application
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
      receivers: [hostmetrics, windowsperfcounters/processor, windowsperfcounters/memory]
      processors: [ memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [windowseventlog]
      processors: [ memory_limiter, batch]
      exporters: [otlphttp/openobserve]
"@

$ConfigContent | Out-File -Path "C:\Program Files\otel-collector\otel-config.yaml"

# Download and install NSSM
$NSSM_ZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
$ExtractionPath = "C:\nssm-2.24"

Invoke-WebRequest -Uri $NSSM_ZipUrl -OutFile "$ExtractionPath.zip"
Expand-Archive -Path "$ExtractionPath.zip" -DestinationPath $ExtractionPath

$architecture = if ([IntPtr]::Size -eq 8) { "win64" } else { "win32" }
$NSSMPath = "$ExtractionPath\nssm-2.24\$architecture\nssm.exe"

# Setup otel-collector as a service using NSSM
& $NSSMPath install "otel-collector" "C:\Program Files\otel-collector\otelcol-contrib.exe" "--config=C:\Program Files\otel-collector\otel-config.yaml"
& $NSSMPath start "otel-collector"

Write-Host "Otel-collector service started using NSSM!"
