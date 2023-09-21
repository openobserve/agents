# Define the script parameters
param (
    [string]$URL,
    [string]$AUTH_KEY
)

# Function to check if NSSM is already installed
function CheckIfNssmInstalled {
    try {
        # Try running the nssm command and check the version
        $output = nssm version
        # If command runs successfully, NSSM is installed
        return $true
    }
    catch {
        # If command fails, NSSM is not installed
        return $false
    }
}

# Check if both URL and AUTH_KEY parameters are provided
if (-not $URL -or -not $AUTH_KEY) {
    Write-Host "Usage: .\install-otel-collector.ps1 -URL <URL> -AUTH_KEY <Authorization_Key>"
    exit 1
}

# Detect the operating system and its architecture
$OS = "windows"
$ARCH = $ENV:PROCESSOR_ARCHITECTURE.ToLower()

if ($ARCH -eq "amd64") {
    $ARCH = "amd64"
} elseif ($ARCH -eq "arm64") {
    $ARCH = "arm64"
}

# Construct the download URL for otel-collector based on OS and architecture
$DOWNLOAD_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.85.0/otelcol-contrib_0.85.0_${OS}_${ARCH}.tar.gz"

# Download otel-collector from the specified URL
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile "otelcol-contrib.tar.gz"

# Ensure the target directory for extraction exists
$directoryPath = "C:\Program Files\otel-collector\"
if (-not (Test-Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory
}

# Extract the downloaded archive to the target directory
tar -xzf "otelcol-contrib.tar.gz" -C "C:\Program Files\otel-collector\"

# Generate a sample configuration file for otel-collector
# [Note: Configuration Content Here]

$ConfigContent | Out-File -Path "C:\Program Files\otel-collector\otel-config.yaml"

# Check if NSSM is already installed
if (-not (CheckIfNssmInstalled)) {
    # If not installed, download NSSM from its source
    $NSSM_ZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $ExtractionPath = "C:\nssm-2.24"

    Invoke-WebRequest -Uri $NSSM_ZipUrl -OutFile "$ExtractionPath.zip"
    Expand-Archive -Path "$ExtractionPath.zip" -DestinationPath $ExtractionPath

    # Determine the architecture to select the correct NSSM executable
    $architecture = if ([IntPtr]::Size -eq 8) { "win64" } else { "win32" }
    $NSSMPath = "$ExtractionPath\nssm-2.24\$architecture\nssm.exe"

    # Add NSSM's path to the system PATH environment variable
    $env:Path += ";$ExtractionPath\nssm-2.24\$architecture"
    [System.Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
    
    # Refresh the current session's PATH to recognize the newly added NSSM path
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
else {
    # If NSSM is already installed, proceed without reinstallation
    Write-Host "NSSM is already installed. Skipping installation."
    $NSSMPath = "nssm"
}

# Check if otel-collector service already exists
try {
    & $NSSMPath status "otel-collector"
    Write-Host "Otel-collector service exists. Removing..."
    # Remove the existing otel-collector service
    & $NSSMPath remove "otel-collector" confirm
    Write-Host "Otel-collector service removed successfully."
}
catch {
    Write-Host "Otel-collector service does not exist. Proceeding with installation."
}

# Set up otel-collector as a new service using NSSM
& $NSSMPath install "otel-collector" "C:\Program Files\otel-collector\otelcol-contrib.exe" "--config=C:\Program Files\otel-collector\otel-config.yaml"
& $NSSMPath start "otel-collector"

# Notify user of successful service start
Write-Host "Otel-collector service started using NSSM!"
