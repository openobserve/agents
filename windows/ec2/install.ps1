# Deprecated: kept only so existing install commands that point here keep working.
# windows/install.ps1 now auto-detects EC2, GCP and Azure; this downloads and runs it.

# Define the script parameters
param (
    [string]$URL,
    [string]$AUTH_KEY
)

$ErrorActionPreference = "Stop"

# GitHub requires TLS 1.2; older Windows/Server defaults to TLS 1.0 and fails the TLS handshake
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$SCRIPT_URL = "https://raw.githubusercontent.com/openobserve/agents/main/windows/install.ps1"

try {
    $script = (Invoke-WebRequest -Uri $SCRIPT_URL -UseBasicParsing).Content
} catch {
    Write-Host "ERROR: Failed to download $SCRIPT_URL"
    Write-Host $_.Exception.Message
    exit 1
}

# Run it in memory, so no second file has to pass the execution policy
& ([scriptblock]::Create($script)) -URL $URL -AUTH_KEY $AUTH_KEY
