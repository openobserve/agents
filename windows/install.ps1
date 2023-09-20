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

# Construct the download URL
$DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.85.0/otelcol-contrib_0.85.0_${OS}_${ARCH}.tar.gz"

# Download the otel-collector binary
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile "otelcol-contrib.tar.gz"

# Extract the binary
tar -xzf "otelcol-contrib.tar.gz" -C "C:\Program Files\"

# Generate a sample configuration file
$ConfigContent = @"
receivers:
  windowseventlog:
        channel: application
  filelog/std:
    include: [ C:\Windows\System32\LogFiles\* ]
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
  otlphttp/openobserve::
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
"@

$ConfigContent | Out-File -Path "C:\Program Files\otel-config.yaml"

# Set up otel-collector to run as a Windows service (This will need additional tools like NSSM)
# Alternatively, you could consider using a Windows-native version of otel-collector which provides Windows service support out of the box

Write-Host "Otel-collector setup completed! Please use a service manager to run it as a Windows service."
"@

# Note: The Windows environment doesn't have a built-in method like `systemd` to manage services. You might need a tool like NSSM (Non-Sucking Service Manager) to easily convert applications into Windows services.

