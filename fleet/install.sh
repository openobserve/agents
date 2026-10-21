#!/bin/bash
#
# Installs the OpenTelemetry collector under the OpAMP supervisor, managed from
# the OpenObserve console (Fleet Management). Linux (systemd) and macOS (launchd).
#
# The script is idempotent: it installs when nothing is installed, upgrades when
# the installed version differs from the requested one, and otherwise just
# rewrites supervisor.yaml and restarts the service. It never writes a collector
# config; that comes from OpenObserve over OpAMP.

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: sudo $0 --url <openobserve url> --org <org> --token <fleet token> [options]
       sudo $0 --uninstall

Options:
  --url URL          OpenObserve base URL, e.g. https://o2.example.com or http://localhost:5080
  --org ORG          OpenObserve organization
  --token TOKEN      Fleet enrollment token from the OpenObserve console
  --transport ws|http
                     OpAMP transport (default: ws). Use http behind proxies that
                     cannot carry WebSocket connections.
  --version X.Y.Z    otelcol-contrib / opampsupervisor version to install
                     (default: fleet/VERSION in the openobserve/agents repo)
  --uninstall        Stop and remove the service, binaries and config. The state
                     directory and logs are kept.
EOF
    exit 1
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

URL=""
ORG=""
TOKEN=""
TRANSPORT="ws"
VERSION=""
UNINSTALL=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=true; shift; continue ;;
        -h|--help) usage ;;
        --url|--org|--token|--transport|--version) ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        die "$1 needs a value"
    fi
    case "$1" in
        --url)       URL=$2 ;;
        --org)       ORG=$2 ;;
        --token)     TOKEN=$2 ;;
        --transport) TRANSPORT=$2 ;;
        --version)   VERSION=$2 ;;
    esac
    shift 2
done

if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (use sudo)"
fi

# ---------------------------------------------------------------------------
# Platform and paths
# ---------------------------------------------------------------------------
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $ARCH (supported: amd64, arm64)" ;;
esac

SERVICE_NAME="opampsupervisor"
INSTALL_DIR="/opt/opampsupervisor"
CONFIG_DIR="/etc/opampsupervisor"
CONFIG_FILE="$CONFIG_DIR/supervisor.yaml"
VERSION_FILE="$INSTALL_DIR/VERSION"

case "$OS" in
    linux)
        STATE_DIR="/var/lib/opampsupervisor"
        LOG_DIR="/var/log/opampsupervisor"
        UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) is required on Linux"
        ;;
    darwin)
        STATE_DIR="/Library/Application Support/opampsupervisor"
        LOG_DIR="/Library/Logs/opampsupervisor"
        LAUNCHD_LABEL="ai.openobserve.opampsupervisor"
        PLIST_FILE="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
        ;;
    *) die "Unsupported OS: $OS (supported: Linux, macOS)" ;;
esac
LOG_FILE="$LOG_DIR/supervisor.log"

SUPERVISOR_BIN="$INSTALL_DIR/opampsupervisor"
COLLECTOR_BIN="$INSTALL_DIR/otelcol-contrib"

# ---------------------------------------------------------------------------
# Service helpers
# ---------------------------------------------------------------------------
service_exists() {
    if [ "$OS" = "linux" ]; then
        [ -f "$UNIT_FILE" ]
    else
        [ -f "$PLIST_FILE" ]
    fi
}

service_stop() {
    if [ "$OS" = "linux" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    else
        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
    fi
}

service_is_running() {
    if [ "$OS" = "linux" ]; then
        systemctl is-active --quiet "$SERVICE_NAME"
    else
        launchctl print "system/$LAUNCHD_LABEL" 2>/dev/null | grep -q 'state = running'
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if $UNINSTALL; then
    if ! service_exists && [ ! -d "$INSTALL_DIR" ] && [ ! -f "$CONFIG_FILE" ]; then
        log "Nothing to uninstall: $SERVICE_NAME is not installed."
        exit 0
    fi
    log "Stopping $SERVICE_NAME"
    service_stop
    if [ "$OS" = "linux" ]; then
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$UNIT_FILE"
        systemctl daemon-reload
        systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    else
        rm -f "$PLIST_FILE"
    fi
    log "Removing $INSTALL_DIR and $CONFIG_DIR"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    log "Uninstalled. Kept state in '$STATE_DIR' and logs in '$LOG_DIR'; delete them by hand if no longer needed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[ -n "$URL" ]   || { echo "ERROR: --url is required" >&2; usage; }
[ -n "$ORG" ]   || { echo "ERROR: --org is required" >&2; usage; }
[ -n "$TOKEN" ] || { echo "ERROR: --token is required" >&2; usage; }

case "$TRANSPORT" in
    ws|http) ;;
    *) die "--transport must be 'ws' or 'http', got '$TRANSPORT'" ;;
esac

URL=$(printf '%s' "$URL" | sed -E 's#/+$##')
case "$URL" in
    http://*)  SCHEME="http" ;;
    https://*) SCHEME="https" ;;
    *) die "--url must start with http:// or https://, got '$URL'" ;;
esac
URL_REST=${URL#*://}
case "$URL_REST" in
    ""|/*) die "--url has no host: '$URL'" ;;
esac
# Keep the config valid YAML and the values usable in URLs and headers.
case "$URL$ORG$TOKEN" in
    *[[:space:]\"\\]*) die "--url, --org and --token may not contain spaces, quotes or backslashes" ;;
esac
[[ "$ORG" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--org may only contain letters, digits, '.', '_' and '-'"

if [ -z "$VERSION" ]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
    VERSION_URL="https://raw.githubusercontent.com/openobserve/agents/main/fleet/VERSION"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/VERSION" ]; then
        VERSION=$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")
    else
        VERSION=$(curl -fsSL "$VERSION_URL" | tr -d '[:space:]') \
            || die "Could not fetch the default collector version from $VERSION_URL; pass --version"
    fi
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must look like 0.163.1, got '$VERSION'"

for tool in curl tar base64; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed"
done
if command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA256="shasum -a 256"
else
    die "'sha256sum' or 'shasum' is required but not installed"
fi

# ---------------------------------------------------------------------------
# Derived settings
# ---------------------------------------------------------------------------
if [ "$TRANSPORT" = "ws" ]; then
    [ "$SCHEME" = "https" ] && OPAMP_SCHEME="wss" || OPAMP_SCHEME="ws"
else
    OPAMP_SCHEME="$SCHEME"
fi
OPAMP_ENDPOINT="${OPAMP_SCHEME}://${URL_REST}/api/${ORG}/v1/opamp"
O2_ENDPOINT="${URL}/api/${ORG}"
AUTH_HEADER="Basic $(printf 'fleet:%s' "$TOKEN" | base64 | tr -d '\n')"
TLS_INSECURE=false
[ "$SCHEME" = "http" ] && TLS_INSECURE=true

RELEASES="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download"
COLLECTOR_ASSET="otelcol-contrib_${VERSION}_${OS}_${ARCH}.tar.gz"
COLLECTOR_URL="${RELEASES}/v${VERSION}/${COLLECTOR_ASSET}"
SUPERVISOR_ASSET="opampsupervisor_${VERSION}_${OS}_${ARCH}"
SUPERVISOR_URL="${RELEASES}/cmd%2Fopampsupervisor%2Fv${VERSION}/${SUPERVISOR_ASSET}"

# ---------------------------------------------------------------------------
# Download and install binaries when absent or at a different version
# ---------------------------------------------------------------------------
INSTALLED_VERSION=""
if [ -x "$SUPERVISOR_BIN" ] && [ -x "$COLLECTOR_BIN" ] && [ -f "$VERSION_FILE" ]; then
    INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Downloads $1 to $2 and checks it against the release's .sha256 file.
fetch() {
    local url=$1 out=$2 expected actual
    log "Downloading $url"
    curl -fsSL --retry 3 "$url" -o "$out" || die "Download failed: $url"
    curl -fsSL --retry 3 "$url.sha256" -o "$out.sha256" || die "Download failed: $url.sha256"
    expected=$(awk '{print $1}' "$out.sha256")
    actual=$($SHA256 "$out" | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Checksum mismatch for $url"
}

if [ "$INSTALLED_VERSION" = "$VERSION" ]; then
    log "Version $VERSION is already installed in $INSTALL_DIR"
else
    if [ -n "$INSTALLED_VERSION" ]; then
        log "Upgrading from $INSTALLED_VERSION to $VERSION"
    else
        log "Installing version $VERSION for $OS/$ARCH"
    fi
    fetch "$COLLECTOR_URL" "$WORKDIR/$COLLECTOR_ASSET"
    fetch "$SUPERVISOR_URL" "$WORKDIR/opampsupervisor"
    mkdir -p "$WORKDIR/collector"
    tar -xzf "$WORKDIR/$COLLECTOR_ASSET" -C "$WORKDIR/collector"
    [ -f "$WORKDIR/collector/otelcol-contrib" ] || die "otelcol-contrib not found in $COLLECTOR_ASSET"
    chmod 755 "$WORKDIR/collector/otelcol-contrib" "$WORKDIR/opampsupervisor"
    "$WORKDIR/collector/otelcol-contrib" --version >/dev/null || die "Downloaded otelcol-contrib does not run on this host"

    if service_exists; then
        log "Stopping $SERVICE_NAME for the upgrade"
        service_stop
    fi
    mkdir -p "$INSTALL_DIR"
    # mv replaces the files atomically and works even if an old binary is still mapped.
    mv -f "$WORKDIR/collector/otelcol-contrib" "$COLLECTOR_BIN"
    mv -f "$WORKDIR/opampsupervisor" "$SUPERVISOR_BIN"
    printf '%s\n' "$VERSION" > "$VERSION_FILE"
    log "Installed otelcol-contrib and opampsupervisor $VERSION into $INSTALL_DIR"
fi

# ---------------------------------------------------------------------------
# Write supervisor.yaml
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"

# Do not add reports_remote_config: the supervisor refuses to start with it set.
umask 077
cat > "$CONFIG_FILE.tmp" <<EOF
# Generated by openobserve/agents fleet/install.sh. Re-run the script to change it.
server:
  endpoint: "${OPAMP_ENDPOINT}"
  headers:
    Authorization: "${AUTH_HEADER}"
  tls:
    insecure: ${TLS_INSECURE}

capabilities:
  accepts_remote_config: true
  reports_effective_config: true
  reports_health: true
  reports_own_metrics: true
  accepts_restart_command: true
  reports_available_components: true

agent:
  executable: "${COLLECTOR_BIN}"
  env:
    O2_ENDPOINT: "${O2_ENDPOINT}"
    O2_TOKEN: "${AUTH_HEADER}"

storage:
  directory: "${STATE_DIR}"

telemetry:
  logs:
    level: info
    encoding: console
    output_paths: ["${LOG_FILE}"]
    error_output_paths: ["${LOG_FILE}"]
EOF
mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
umask 022
log "Wrote $CONFIG_FILE (endpoint ${OPAMP_ENDPOINT})"

# ---------------------------------------------------------------------------
# Install and (re)start the service
# ---------------------------------------------------------------------------
LOG_LINES_BEFORE=0
[ -f "$LOG_FILE" ] && LOG_LINES_BEFORE=$(wc -l < "$LOG_FILE")

if [ "$OS" = "linux" ]; then
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=OpenTelemetry OpAMP supervisor (OpenObserve fleet)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${SUPERVISOR_BIN} --config ${CONFIG_FILE}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    log "Starting $SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
else
    cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SUPERVISOR_BIN}</string>
        <string>--config</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST_FILE"
    chmod 644 "$PLIST_FILE"
    log "Starting $LAUNCHD_LABEL"
    launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
    launchctl bootstrap system "$PLIST_FILE"
fi

# Wait for the supervisor to connect so a bad URL or token fails loudly here.
CONNECTED=false
for _ in $(seq 1 30); do
    sleep 1
    if ! service_is_running; then
        break
    fi
    if [ -f "$LOG_FILE" ] && tail -n "+$((LOG_LINES_BEFORE + 1))" "$LOG_FILE" | grep -q 'Connected to the OpAMP server'; then
        CONNECTED=true
        break
    fi
done

if ! service_is_running; then
    echo "ERROR: $SERVICE_NAME is not running. Last log lines from $LOG_FILE:" >&2
    [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" >&2
    [ "$OS" = "darwin" ] && [ -f "$LOG_DIR/launchd.log" ] && tail -n 20 "$LOG_DIR/launchd.log" >&2
    exit 1
fi

if $CONNECTED; then
    log "Connected to OpenObserve at ${OPAMP_ENDPOINT}. The collector will show up in the console shortly."
else
    warn "The supervisor is running but has not connected to ${OPAMP_ENDPOINT} yet. Check the URL and token:"
    tail -n "+$((LOG_LINES_BEFORE + 1))" "$LOG_FILE" | grep -E 'error|Failed' | tail -n 5 >&2 || true
fi
log "Supervisor log: $LOG_FILE"
log "Collector log:  $STATE_DIR/agent.log"
