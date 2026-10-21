<#
.SYNOPSIS
Installs the OpenTelemetry collector under the OpAMP supervisor, managed from the
OpenObserve console (Fleet Management), as a Windows service.

.DESCRIPTION
Idempotent: installs when nothing is installed, upgrades when the installed version
differs from the requested one, and otherwise just rewrites supervisor.yaml and
restarts the service. It never writes a collector config; that comes from
OpenObserve over OpAMP. Run from an elevated PowerShell.

.EXAMPLE
.\install.ps1 -Url https://o2.example.com -Org default -Token o2ft_xxx

.EXAMPLE
.\install.ps1 -Uninstall
#>
[CmdletBinding()]
param (
    [string]$Url,
    [string]$Org,
    [string]$Token,
    [ValidateSet("ws", "http")]
    [string]$Transport = "ws",
    [string]$Version,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Fail($Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "This script must be run from an elevated (Administrator) PowerShell"
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ServiceName  = "opampsupervisor"
$InstallDir   = Join-Path $env:ProgramFiles "opampsupervisor"
$DataDir      = Join-Path $env:ProgramData "opampsupervisor"
$ConfigFile   = Join-Path $DataDir "supervisor.yaml"
$StateDir     = Join-Path $DataDir "state"
$VersionFile  = Join-Path $InstallDir "VERSION"
$SupervisorExe = Join-Path $InstallDir "opampsupervisor.exe"
$CollectorExe  = Join-Path $InstallDir "otelcol-contrib.exe"

function Get-SupervisorService {
    Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

function Stop-SupervisorService {
    $svc = Get-SupervisorService
    if ($svc -and $svc.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    }
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall) {
    $svc = Get-SupervisorService
    if (-not $svc -and -not (Test-Path $InstallDir) -and -not (Test-Path $ConfigFile)) {
        Write-Host "Nothing to uninstall: $ServiceName is not installed."
        exit 0
    }
    if ($svc) {
        Write-Host "Stopping and removing service $ServiceName"
        Stop-SupervisorService
        sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "sc.exe delete $ServiceName failed (exit code $LASTEXITCODE)" }
    }
    Write-Host "Removing $InstallDir and $ConfigFile"
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    if (Test-Path $ConfigFile) { Remove-Item -Force $ConfigFile }
    Write-Host "Uninstalled. Kept state in '$StateDir'; delete it by hand if no longer needed."
    exit 0
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if (-not $Url -or -not $Org -or -not $Token) {
    Write-Host "Usage: .\install.ps1 -Url <openobserve url> -Org <org> -Token <fleet token> [-Transport ws|http] [-Version X.Y.Z]"
    Write-Host "       .\install.ps1 -Uninstall"
    exit 1
}

$Url = $Url.TrimEnd("/")
if ($Url -match '^(https?)://([^/]+)(/.*)?$') {
    $Scheme = $Matches[1]
    $UrlRest = $Url.Substring($Scheme.Length + 3)
} else {
    Fail "-Url must start with http:// or https:// and contain a host, got '$Url'"
}
if ("$Url$Org$Token" -match '[\s"''\\]') {
    Fail "-Url, -Org and -Token may not contain spaces, quotes or backslashes"
}
if ($Org -notmatch '^[A-Za-z0-9_.-]+$') {
    Fail "-Org may only contain letters, digits, '.', '_' and '-'"
}

if (-not $Version) {
    $localVersionFile = Join-Path $PSScriptRoot "VERSION"
    $versionUrl = "https://raw.githubusercontent.com/openobserve/agents/main/fleet/VERSION"
    if ($PSScriptRoot -and (Test-Path $localVersionFile)) {
        $Version = (Get-Content $localVersionFile -Raw).Trim()
    } else {
        try {
            $Version = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing).Content.Trim()
        } catch {
            Fail "Could not fetch the default collector version from $versionUrl ($($_.Exception.Message)); pass -Version"
        }
    }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "-Version must look like 0.163.1, got '$Version'"
}

# The supervisor is only published for windows/amd64 upstream.
$Arch = $env:PROCESSOR_ARCHITECTURE.ToLower()
if ($Arch -ne "amd64") {
    Fail "Unsupported architecture: $Arch (the OpAMP supervisor is only released for windows/amd64)"
}

# The collector ships for Windows only as .tar.gz, which needs the built-in tar.exe.
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Fail "tar.exe not found. Windows 10 1803+ or Windows Server 2019+ is required."
}

# GitHub requires TLS 1.2; older Windows defaults to TLS 1.0 and fails the handshake.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Derived settings
# ---------------------------------------------------------------------------
if ($Transport -eq "ws") {
    $OpampScheme = if ($Scheme -eq "https") { "wss" } else { "ws" }
} else {
    $OpampScheme = $Scheme
}
$OpampEndpoint = "${OpampScheme}://${UrlRest}/api/${Org}/v1/opamp"
$O2Endpoint = "${Url}/api/${Org}"
$AuthHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("fleet:$Token"))
$TlsInsecure = if ($Scheme -eq "http") { "true" } else { "false" }

$Releases = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download"
$CollectorAsset = "otelcol-contrib_${Version}_windows_amd64.tar.gz"
$CollectorUrl = "${Releases}/v${Version}/${CollectorAsset}"
$SupervisorAsset = "opampsupervisor_${Version}_windows_amd64.exe"
$SupervisorUrl = "${Releases}/cmd%2Fopampsupervisor%2Fv${Version}/${SupervisorAsset}"

# ---------------------------------------------------------------------------
# Download and install binaries when absent or at a different version
# ---------------------------------------------------------------------------
$InstalledVersion = ""
if ((Test-Path $SupervisorExe) -and (Test-Path $CollectorExe) -and (Test-Path $VersionFile)) {
    $InstalledVersion = (Get-Content $VersionFile -Raw).Trim()
}

# Downloads $Uri to $OutFile and checks it against the release's .sha256 file.
function Get-ReleaseAsset($Uri, $OutFile) {
    Write-Host "Downloading $Uri"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
        Invoke-WebRequest -Uri "$Uri.sha256" -OutFile "$OutFile.sha256" -UseBasicParsing
    } catch {
        Fail "Download failed: $Uri ($($_.Exception.Message))"
    }
    $expected = ((Get-Content "$OutFile.sha256" -Raw).Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 $OutFile).Hash.ToLower()
    if (-not $expected -or $expected -ne $actual) {
        Fail "Checksum mismatch for $Uri"
    }
}

$WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("opampsupervisor-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $WorkDir | Out-Null
try {
    if ($InstalledVersion -eq $Version) {
        Write-Host "Version $Version is already installed in $InstallDir"
    } else {
        if ($InstalledVersion) {
            Write-Host "Upgrading from $InstalledVersion to $Version"
        } else {
            Write-Host "Installing version $Version for windows/amd64"
        }
        $collectorArchive = Join-Path $WorkDir $CollectorAsset
        $supervisorTmp = Join-Path $WorkDir "opampsupervisor.exe"
        Get-ReleaseAsset $CollectorUrl $collectorArchive
        Get-ReleaseAsset $SupervisorUrl $supervisorTmp

        $extractDir = Join-Path $WorkDir "collector"
        New-Item -ItemType Directory -Path $extractDir | Out-Null
        tar -xzf $collectorArchive -C $extractDir
        if ($LASTEXITCODE -ne 0) { Fail "tar extraction failed (exit code $LASTEXITCODE)" }
        $collectorTmp = Join-Path $extractDir "otelcol-contrib.exe"
        if (-not (Test-Path $collectorTmp)) { Fail "otelcol-contrib.exe not found in $CollectorAsset" }
        Unblock-File -Path $collectorTmp, $supervisorTmp

        # The service must be stopped before its binaries can be replaced.
        if (Get-SupervisorService) {
            Write-Host "Stopping $ServiceName for the upgrade"
            Stop-SupervisorService
        }
        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
        Move-Item -Force $collectorTmp $CollectorExe
        Move-Item -Force $supervisorTmp $SupervisorExe
        Set-Content -Path $VersionFile -Value $Version -NoNewline
        Write-Host "Installed otelcol-contrib and opampsupervisor $Version into $InstallDir"
    }
} finally {
    Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Write supervisor.yaml
# ---------------------------------------------------------------------------
foreach ($dir in $DataDir, $StateDir) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

# YAML single-quoted scalars: backslashes in Windows paths need no escaping.
# Do not add reports_remote_config: the supervisor refuses to start with it set.
# Running as a service, the supervisor logs to the Windows Application event log
# (source opampsupervisor), so telemetry.logs.output_paths would be ignored.
$ConfigContent = @"
# Generated by openobserve/agents fleet/install.ps1. Re-run the script to change it.
server:
  endpoint: '$OpampEndpoint'
  headers:
    Authorization: '$AuthHeader'
  tls:
    insecure: $TlsInsecure

capabilities:
  accepts_remote_config: true
  reports_effective_config: true
  reports_health: true
  reports_own_metrics: true
  accepts_restart_command: true
  reports_available_components: true

agent:
  executable: '$CollectorExe'
  env:
    O2_ENDPOINT: '$O2Endpoint'
    O2_TOKEN: '$AuthHeader'

storage:
  directory: '$StateDir'

telemetry:
  logs:
    level: info
    encoding: console
"@
[IO.File]::WriteAllText($ConfigFile, $ConfigContent.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))

# Equivalent of mode 600: only SYSTEM and Administrators can read the token.
$acl = Get-Acl $ConfigFile
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
foreach ($id in "NT AUTHORITY\SYSTEM", "BUILTIN\Administrators") {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, "FullControl", "Allow")))
}
Set-Acl -Path $ConfigFile -AclObject $acl
Write-Host "Wrote $ConfigFile (endpoint $OpampEndpoint)"

# ---------------------------------------------------------------------------
# Install and (re)start the service
# ---------------------------------------------------------------------------
$BinPath = "`"$SupervisorExe`" --config `"$ConfigFile`""
$DisplayName = "OpenTelemetry OpAMP supervisor (OpenObserve fleet)"
if (-not (Get-SupervisorService)) {
    New-Service -Name $ServiceName -BinaryPathName $BinPath -DisplayName $DisplayName -StartupType Automatic `
        -Description "Runs otelcol-contrib under the OpAMP supervisor, managed from the OpenObserve console." | Out-Null
} else {
    sc.exe config $ServiceName binPath= $BinPath start= auto | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "sc.exe config $ServiceName failed (exit code $LASTEXITCODE)" }
}
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "sc.exe failure $ServiceName failed (exit code $LASTEXITCODE)" }

# Register the event log source so the supervisor's messages render in Event Viewer.
try {
    if (-not [Diagnostics.EventLog]::SourceExists($ServiceName)) {
        New-EventLog -LogName Application -Source $ServiceName
    }
} catch {
    Write-Host "WARNING: could not register event log source ${ServiceName}: $($_.Exception.Message)"
}

$StartTime = Get-Date
Write-Host "Starting $ServiceName"
Stop-SupervisorService
Start-Service -Name $ServiceName

# Wait for the supervisor to connect so a bad URL or token fails loudly here.
$Connected = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $svc = Get-SupervisorService
    if ($svc.Status -ne "Running") { break }
    $events = Get-WinEvent -FilterHashtable @{ LogName = "Application"; ProviderName = $ServiceName; StartTime = $StartTime } -ErrorAction SilentlyContinue
    if ($events | Where-Object { $_.Message -match "Connected to the OpAMP server" }) {
        $Connected = $true
        break
    }
}

$svc = Get-SupervisorService
if ($svc.Status -ne "Running") {
    Write-Host "ERROR: $ServiceName is not running (status $($svc.Status)). Recent events:" -ForegroundColor Red
    Get-WinEvent -FilterHashtable @{ LogName = "Application"; ProviderName = $ServiceName; StartTime = $StartTime } -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Host $_.Message }
    exit 1
}

if ($Connected) {
    Write-Host "Connected to OpenObserve at $OpampEndpoint. The collector will show up in the console shortly."
} else {
    Write-Host "WARNING: the supervisor is running but has not connected to $OpampEndpoint yet. Check the URL and token:"
    Get-WinEvent -FilterHashtable @{ LogName = "Application"; ProviderName = $ServiceName; StartTime = $StartTime } -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -eq "Error" } | Select-Object -First 5 | ForEach-Object { Write-Host $_.Message }
}
Write-Host "Supervisor log: Event Viewer > Windows Logs > Application, source $ServiceName"
Write-Host "Collector log:  $StateDir\agent.log"
