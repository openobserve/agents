# Fleet Management install scripts

These scripts install the OpenTelemetry collector (`otelcol-contrib`) under the
official OpAMP supervisor (`opampsupervisor`) and connect it to OpenObserve, where
Fleet Management pushes the collector configuration and upgrades. The scripts write
only the supervisor configuration and a service definition; the collector config
itself always comes from the OpenObserve console.

Both binaries are downloaded from the upstream
[opentelemetry-collector-releases](https://github.com/open-telemetry/opentelemetry-collector-releases/releases)
GitHub releases and verified against their published SHA-256 checksums. The default
version is the one in [VERSION](VERSION); the OpenObserve console passes the
organization's target version with `--version`.

## Install

Get a fleet token from the OpenObserve console (Fleet > Tokens), then run the command
the console shows for the host's platform. The command needs root on Linux and macOS
and an elevated PowerShell on Windows.

Linux and macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/agents/main/fleet/install.sh -o install.sh && sudo bash install.sh --url https://o2.example.com --org default --token <fleet token>
```

Windows (PowerShell as Administrator):

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/openobserve/agents/main/fleet/install.ps1 -OutFile install.ps1; .\install.ps1 -Url https://o2.example.com -Org default -Token <fleet token>
```

The script downloads the binaries, writes `supervisor.yaml`, installs a service, starts
it and waits up to 30 seconds for the supervisor to connect. It fails with the last log
lines if the service dies, and warns if it is running but has not connected yet
(usually a wrong URL or token).

## Flags

| Linux / macOS | Windows | Meaning |
|---|---|---|
| `--url URL` | `-Url URL` | OpenObserve base URL, e.g. `https://o2.example.com` or `http://localhost:5080`. Required. |
| `--org ORG` | `-Org ORG` | OpenObserve organization. Required. |
| `--token TOKEN` | `-Token TOKEN` | Fleet token from the console. Required. |
| `--transport http\|ws` | `-Transport http\|ws` | OpAMP transport. Default `http` (polls every 30s; works wherever ingestion works). `ws` (WebSocket) pushes config changes instantly but needs every proxy/load balancer on the path to carry WebSocket connections. |
| `--version X.Y.Z` | `-Version X.Y.Z` | `otelcol-contrib` and `opampsupervisor` version. Default: [VERSION](VERSION). |
| `--uninstall` | `-Uninstall` | Remove the service, binaries and config. |

The OpAMP endpoint is derived from `--url`: `https://` stays `https://` (or becomes
`wss://` with `--transport ws`), and `http://` stays `http://` (or becomes `ws://`) with
TLS verification disabled, for local or lab setups only.

## Paths

| | Linux | macOS | Windows |
|---|---|---|---|
| Binaries | `/opt/opampsupervisor/` | `/opt/opampsupervisor/` | `C:\Program Files\opampsupervisor\` |
| Config (mode 600) | `/etc/opampsupervisor/supervisor.yaml` | `/etc/opampsupervisor/supervisor.yaml` | `C:\ProgramData\opampsupervisor\supervisor.yaml` |
| State (instance id, last config) | `/var/lib/opampsupervisor/` | `/Library/Application Support/opampsupervisor/` | `C:\ProgramData\opampsupervisor\state\` |
| Supervisor log | `/var/log/opampsupervisor/supervisor.log` | `/Library/Logs/opampsupervisor/supervisor.log` | Event Viewer > Application, source `opampsupervisor` |
| Collector log | `/var/lib/opampsupervisor/agent.log` | `/Library/Application Support/opampsupervisor/agent.log` | `C:\ProgramData\opampsupervisor\state\agent.log` |
| Service | systemd `opampsupervisor.service` | launchd `ai.openobserve.opampsupervisor` | Windows service `opampsupervisor` |

The service runs as root (Linux, macOS) or LocalSystem (Windows), since the collector
configuration pushed from the console may read system logs and metrics.

Useful commands:

```bash
# Linux
systemctl status opampsupervisor
tail -f /var/log/opampsupervisor/supervisor.log
# macOS
sudo launchctl print system/ai.openobserve.opampsupervisor
tail -f /Library/Logs/opampsupervisor/supervisor.log
```

```powershell
Get-Service opampsupervisor
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='opampsupervisor'} -MaxEvents 20
```

## Upgrade

Re-run the install command with the new `--version` (or without it to get the
version in [VERSION](VERSION)). When the installed version differs, the script
downloads the new binaries, stops the service, swaps them and starts it again. The
state directory is kept, so the collector keeps its identity in the console.

## Switch token or server

Re-run the install command with the new `--token`, `--url`, `--org` or
`--transport`. When the version is unchanged, the script only rewrites
`supervisor.yaml` and restarts the service.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

```powershell
.\install.ps1 -Uninstall
```

This stops and removes the service, the binaries and the config. The state directory
(and on Linux and macOS the log directory) is kept, so re-installing brings the same
collector back; delete it by hand to start fresh.

## Supervisor configuration

The generated `supervisor.yaml` connects to `<scheme>://<host>/api/<org>/v1/opamp`
with `Authorization: Basic base64(fleet:<token>)`, enables the
`accepts_remote_config`, `reports_effective_config`, `reports_health`,
`reports_own_metrics`, `accepts_restart_command` and `reports_available_components`
capabilities, sets `agent.config_apply_timeout` to `30s` (the supervisor's 5s default
also covers stopping the old collector and is too short for many hosts), and passes
`O2_ENDPOINT` (`<url>/api/<org>`) and `O2_TOKEN` to the collector so the pushed
configuration can reference them as `${env:O2_ENDPOINT}` and `${env:O2_TOKEN}`. Edit it only through the script: a re-run overwrites it.

## Platforms

Linux amd64 and arm64 (systemd), macOS arm64 and amd64 (launchd), Windows amd64
(Windows 10 1803+ or Server 2019+, for the built-in `tar`). Upstream does not publish
the supervisor for Windows arm64.
