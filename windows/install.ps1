param (
    [string]$URL,
    [string]$AUTH_KEY
)

function CheckIfNssmInstalled {
    try {
        # Attempt to run the nssm command
        $output = nssm version
        # If the above command did not throw an error, nssm is installed
        return $true
    }
    catch {
        # An error occurred, so nssm is not installed
        return $false
    }
}

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

# Create the directory to extract the binary
$directoryPath = "C:\Program Files\otel-collector\"
if (-not (Test-Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory
}

# Extract the binary
tar -xzf "otelcol-contrib.tar.gz" -C "C:\Program Files\otel-collector\"

# Generate a sample configuration file
# [Note: Configuration Content Here]

$ConfigContent | Out-File -Path "C:\Program Files\otel-collector\otel-config.yaml"

if (-not (CheckIfNssmInstalled)) {
    # Download and install NSSM if not already installed
    $NSSM_ZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $ExtractionPath = "C:\nssm-2.24"

    Invoke-WebRequest -Uri $NSSM_ZipUrl -OutFile "$ExtractionPath.zip"
    Expand-Archive -Path "$ExtractionPath.zip" -DestinationPath $ExtractionPath

    $architecture = if ([IntPtr]::Size -eq 8) { "win64" } else { "win32" }
    $NSSMPath = "$ExtractionPath\nssm-2.24\$architecture\nssm.exe"
    
    # Add NSSM to system PATH
    $env:Path += ";$ExtractionPath\nssm-2.24\$architecture"
    [System.Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
    
    # Refresh current session PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
else {
    Write-Host "NSSM is already installed. Skipping installation."
    # Assuming NSSM is in the system's PATH. If not, you may need to specify the full path.
    $NSSMPath = "nssm"
}

# Setup otel-collector as a service using NSSM
& $NSSMPath install "otel-collector" "C:\Program Files\otel-collector\otelcol-contrib.exe" "--config=C:\Program Files\otel-collector\otel-config.yaml"
& $NSSMPath start "otel-collector"

Write-Host "Otel-collector service started using NSSM!"
