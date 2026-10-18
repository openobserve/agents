#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 <URL> <Authorization_Key> [tracing options]

eBPF tracing (OBI) is optional, and on only when at least one --trace-* flag is given:
  --trace-ports LIST    trace processes using these local ports, e.g. 80,443,8000-8999 (repeatable)
  --trace-exe GLOB      trace processes whose executable path matches GLOB (repeatable)
  --trace-cmd GLOB      trace processes whose command line matches GLOB (repeatable)
  --service-name NAME   report every traced process as service.name=NAME
EOF
    exit 1
}

if [ "$#" -lt 2 ]; then
    usage
fi

URL=$1
AUTH_KEY=$2
shift 2

TRACE_PORTS=""
TRACE_EXE=()
TRACE_CMD=()
SERVICE_NAME=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --trace-ports|--trace-exe|--trace-cmd|--service-name) ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 needs a value" >&2
        exit 1
    fi
    case "$1" in
        --trace-ports)  TRACE_PORTS="${TRACE_PORTS:+$TRACE_PORTS,}$2" ;;
        --trace-exe)    TRACE_EXE+=("$2") ;;
        --trace-cmd)    TRACE_CMD+=("$2") ;;
        --service-name) SERVICE_NAME=$2 ;;
    esac
    shift 2
done

TRACING=false
if [ -n "$TRACE_PORTS" ] || [ "${#TRACE_EXE[@]}" -gt 0 ] || [ "${#TRACE_CMD[@]}" -gt 0 ]; then
    TRACING=true
fi

# Check the values before anything is installed or restarted. OBI itself rejects
# malformed port lists and bad rules in the pre-flight validate further down; these
# checks cover what it doesn't, and keep the values from breaking out of the YAML.
if [ -n "$SERVICE_NAME" ] && ! $TRACING; then
    echo "ERROR: --service-name needs at least one of --trace-ports, --trace-exe or --trace-cmd" >&2
    exit 1
fi
if [ -n "$SERVICE_NAME" ] && [[ ! "$SERVICE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: --service-name may only contain letters, digits, '.', '_' and '-'" >&2
    exit 1
fi
if [ -n "$TRACE_PORTS" ]; then
    if [[ ! "$TRACE_PORTS" =~ ^[0-9,-]+$ ]]; then
        echo "ERROR: --trace-ports takes ports and port ranges, e.g. 80,443,8000-8999" >&2
        exit 1
    fi
    for port in ${TRACE_PORTS//[,-]/ }; do
        if [ "${#port}" -gt 5 ] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
            echo "ERROR: --trace-ports: $port is not a port between 1 and 65535" >&2
            exit 1
        fi
    done
fi
# OBI joins repeated globs into one {a,b} pattern, so these characters would
# silently change what matches.
for glob in ${TRACE_EXE[@]+"${TRACE_EXE[@]}"} ${TRACE_CMD[@]+"${TRACE_CMD[@]}"}; do
    case "$glob" in
        *[,{}]*)
            echo "ERROR: --trace-exe and --trace-cmd globs may not contain ',', '{' or '}': $glob" >&2
            exit 1
            ;;
    esac
done

# Prints a YAML single-quoted string.
yaml_quote() {
    local q="'"
    printf "'%s'" "${1//$q/$q$q}"
}

# Prints a YAML flow list of single-quoted strings.
yaml_list() {
    local item out=""
    for item in "$@"; do
        out+="${out:+, }$(yaml_quote "$item")"
    done
    printf '[%s]' "$out"
}

# Ensure the 'openobserve-agent' group and user exist.
# Create the group first, then the user with it as the primary group, instead of
# relying on useradd's implicit group creation and a separate groupadd check.
if ! getent group openobserve-agent >/dev/null; then
    groupadd --system openobserve-agent
fi

if ! id -u openobserve-agent &>/dev/null; then
    useradd --system --gid openobserve-agent openobserve-agent
fi

# Grant log-read access on every run (not just first-time creation) so existing
# installs get corrected too.
usermod -aG systemd-journal openobserve-agent            # read journald logs
if getent group adm >/dev/null; then
    usermod -aG adm openobserve-agent                    # read /var/log files owned by root:adm
fi

# Detect OS and architecture
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
OTEL_VERSION="0.163.1"

case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

# Construct the download URL
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}.tar.gz"

# Download and install the binary inside a temp workdir that is always cleaned up,
# with a hard failure on any download or extraction error.
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" /usr/local/bin/otelcol-contrib.new' EXIT

echo "Downloading $DOWNLOAD_URL"
if ! curl -fL "$DOWNLOAD_URL" -o "$WORKDIR/otelcol-contrib.tar.gz"; then
    echo "ERROR: Failed to download otel-collector from $DOWNLOAD_URL" >&2
    exit 1
fi

# Sanity check: make sure we got a real archive, not an empty or error response.
if [ ! -s "$WORKDIR/otelcol-contrib.tar.gz" ] || [ "$(stat -c%s "$WORKDIR/otelcol-contrib.tar.gz")" -lt 1024 ]; then
    echo "ERROR: Downloaded archive is missing or too small. Aborting." >&2
    exit 1
fi

tar -xzf "$WORKDIR/otelcol-contrib.tar.gz" -C "$WORKDIR"

# The tracing parts of the configuration; all empty without tracing.
OBI_RECEIVER=""
SERVICE_NAME_PROCESSOR=""
TRACES_PIPELINE=""
if $TRACING; then
    OBI_RULES=""
    if [ -n "$TRACE_PORTS" ]; then
        OBI_RULES+="
      - action: include
        name: ports
        match:
          process:
            open_ports: $(yaml_quote "$TRACE_PORTS")"
    fi
    if [ "${#TRACE_EXE[@]}" -gt 0 ]; then
        OBI_RULES+="
      - action: include
        name: exe
        match:
          process:
            exe_path_glob: $(yaml_list "${TRACE_EXE[@]}")"
    fi
    if [ "${#TRACE_CMD[@]}" -gt 0 ]; then
        OBI_RULES+="
      - action: include
        name: cmd
        match:
          process:
            cmd_args_glob: $(yaml_list "${TRACE_CMD[@]}")"
    fi

    # Built-in exclusions don't apply once rules are given, so the infra rule
    # keeps a broad selector from tracing the collector itself or Docker's port
    # forwarder, and already-instrumented stops OBI sending spans for a process
    # once it sees that process export its own traces.
    OBI_RECEIVER="
  # eBPF tracing (OBI), generated from the install flags. When editing the rules:
  # exclude rules must come before include rules, and rules must all use globs
  # (*_glob) or all use regexes (*_regex), not both. Keep the infra exclusion;
  # exports_otlp must be alone in its rule.
  obi:
    version: \"2.0\"
    safety:
      enforce_system_capabilities: true
    # Adds a traceparent header to outgoing plain-text HTTP requests and reads
    # incoming ones, so a trace continues on other hosts that run OBI.
    engine:
      propagation:
        context_propagation: headers
    policy:
      default_action: exclude
      match_order: first_match_wins
    rules:
      - action: exclude
        name: infra
        match:
          process:
            exe_path_glob: ['*/otelcol-contrib', '*/docker-proxy']
      - action: exclude
        name: already-instrumented
        match:
          process:
            exports_otlp:
              port: 4317
              protocol: protobuf$OBI_RULES"

    TRACES_PROCESSORS="resourcedetection, resource/hostname"
    if [ -n "$SERVICE_NAME" ]; then
        SERVICE_NAME_PROCESSOR="
  # Reports every traced process under one service name, overriding the app's own.
  resource/service_name:
    attributes:
      - key: service.name
        value: \"$SERVICE_NAME\"
        action: upsert"
        TRACES_PROCESSORS+=", resource/service_name"
    fi

    TRACES_PIPELINE="
    traces:
      receivers: [obi]
      processors: [$TRACES_PROCESSORS, memory_limiter, batch]
      exporters: [otlphttp/openobserve]"
fi

# Generate the configuration file in the workdir; it is checked (with tracing)
# before anything on the host is replaced.
cat > "$WORKDIR/otel-config.yaml" <<EOL
receivers:
  journald:
    directory: /var/log/journal
  filelog/std:
    include: [ /var/log/**log ]
    # start_at: beginning
  hostmetrics:
    root_path: /
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
      # process: # a bug in the process scraper causes the collector to throw errors so disabling it for now$OBI_RECEIVER
processors:
  # Detects plain hosts, AWS EC2, GCP Compute Engine and Azure VMs; off their cloud
  # the cloud detectors add nothing. "system" comes first because the first detector
  # to set an attribute wins, so host.name stays the OS hostname everywhere. Reading
  # the EC2 Name tag needs an IAM role with ec2:DescribeTags; without it the tag is skipped.
  resourcedetection:
    detectors: ["system", "ec2", "gcp", "azure"]
    ec2:
      tags:
        - ^Name$
    system:
      hostname_sources: ["os"]
  # Sets host.name to the EC2 instance Name tag when present; a no-op otherwise.
  resource/hostname:
    attributes:
      - key: host.name
        from_attribute: ec2.tag.Name
        action: upsert
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 15
  batch:
    send_batch_size: 10000
    timeout: 10s$SERVICE_NAME_PROCESSOR

extensions:
  zpages: {}

exporters:
  otlphttp/openobserve:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
  otlphttp/openobserve_journald:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
      stream-name: journald

service:
  extensions: [zpages]
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource/hostname, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [filelog/std]
      processors: [resourcedetection, resource/hostname, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs/journald:
      receivers: [journald]
      processors: [resourcedetection, resource/hostname, memory_limiter, batch]
      exporters: [otlphttp/openobserve_journald]$TRACES_PIPELINE
EOL

# Staged next to the installed binary, since /tmp may be mounted noexec.
install -m 0755 "$WORKDIR/otelcol-contrib" /usr/local/bin/otelcol-contrib.new

# Pre-flight: OBI checks the kernel version, BTF and capabilities when the
# collector builds its pipelines, which validate also does. Run it with the new
# binary before replacing anything, so a failure leaves an existing install working.
if $TRACING; then
    echo "Checking that eBPF tracing can run on this host"
    if ! /usr/local/bin/otelcol-contrib.new validate --config "$WORKDIR/otel-config.yaml"; then
        rm -f /usr/local/bin/otelcol-contrib.new
        echo "ERROR: The new configuration was rejected (see the error above): eBPF tracing can't run on this host, or a value is invalid." >&2
        echo "The installed collector, its config and the service were not changed. Re-run without the --trace-* flags to install without tracing." >&2
        exit 1
    fi
fi

mv -f /usr/local/bin/otelcol-contrib.new /usr/local/bin/otelcol-contrib
# cp keeps the mode of an existing file
cp "$WORKDIR/otel-config.yaml" /etc/otel-config.yaml

# OBI needs root-level privileges: beyond loading eBPF programs, it switches to a
# JVM's user to attach its Java agent and signals Node.js processes.
if $TRACING; then
    RUN_AS=root
else
    RUN_AS=openobserve-agent
fi

# Set up otel-collector to run as a systemd service
cat > /etc/systemd/system/otel-collector.service <<EOL
[Unit]
Description=OpenTelemetry Collector
After=network.target network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/otel-config.yaml
Restart=always
RestartSec=10
User=$RUN_AS
Group=$RUN_AS

[Install]
WantedBy=multi-user.target
EOL

# With tracing, a failure stops and disables the collector, logs and metrics
# included, so it can't come back half-working at boot or go unnoticed.
fail() {
    echo "Last collector log lines:" >&2
    journalctl -u otel-collector -n 15 -o cat -q --no-pager >&2 || true
    echo "ERROR: $1" >&2
    if $TRACING; then
        systemctl stop otel-collector || true
        systemctl disable --quiet otel-collector || true
        echo "otel-collector has been stopped and disabled, so logs and metrics are stopped too." >&2
        echo "Either re-run without the --trace-* flags, or fix the cause (usually missing privileges or kernel support) and re-run with them." >&2
    fi
    echo "Inspect logs with: journalctl -u otel-collector -n 50" >&2
    exit 1
}

# Reload systemd and (re)start the service. Use restart so re-runs pick up the
# new binary/config instead of no-op'ing when it is already running.
systemctl daemon-reload
systemctl enable otel-collector
if $TRACING; then
    # Only log lines after this point belong to the new run. The time is the
    # fallback for when there is no cursor (an empty journal on older systemd).
    CURSOR=$(journalctl --show-cursor -n 0 -q | sed -n 's/^-- cursor: //p') || true
    SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -n "$CURSOR" ]; then
        BOUNDARY=(--after-cursor "$CURSOR")
    else
        BOUNDARY=(--since "$SINCE")
    fi
fi
if ! systemctl restart otel-collector; then
    fail "otel-collector failed to start."
fi

# Verify the service actually came up instead of unconditionally reporting success.
if ! $TRACING; then
    if ! systemctl is-active --quiet otel-collector; then
        fail "otel-collector failed to start."
    fi
    echo "Otel-collector service started!"
    exit 0
fi

# With tracing, check longer: OBI starts in the background, after the collector.
# A crash shows as a changed main PID (and restart count, on systemd 235+).
STARTED=$(systemctl show -p MainPID -p NRestarts otel-collector) || true
still_up() {
    systemctl is-active --quiet otel-collector &&
        [ "$(systemctl show -p MainPID -p NRestarts otel-collector)" = "$STARTED" ]
}

# The collector logs "Everything is ready" once all receivers have started. Off a
# cloud this takes 20 seconds or more: the cloud detectors time out once per pipeline.
echo "Waiting for otel-collector to start (up to 90 seconds)"
READY=false
# (grep reads all input: with -q, journalctl could die of SIGPIPE and fail the pipeline.)
for _ in $(seq 90); do
    still_up || fail "otel-collector did not stay up."
    if journalctl -u otel-collector "${BOUNDARY[@]}" -o cat -q --no-pager 2>/dev/null | grep 'Everything is ready' >/dev/null; then
        READY=true
        break
    fi
    sleep 1
done
$READY || fail "otel-collector did not finish starting within 90 seconds."

# A crash shortly after start-up, and OBI picking up the selected processes (it
# waits until a process is 5 seconds old), still need a moment.
sleep 10
still_up || fail "otel-collector did not stay up."

LOGS=$(journalctl -u otel-collector "${BOUNDARY[@]}" -o cat -q --no-pager) ||
    fail "could not read the otel-collector logs to check eBPF tracing."

# OBI starts capturing in the background, so these failures don't stop the
# collector by themselves. Each means OBI as a whole has stopped tracing.
if FATAL=$(grep -E 'Unable to load eBPF watcher for process events|cant start process tracer' <<<"$LOGS"); then
    echo "$FATAL" >&2
    fail "eBPF tracing failed to start (see the OBI errors above)."
fi

# OBI couldn't load its eBPF programs for a process. Other processes may still be
# traced, so this warns instead of stopping logs and metrics for the whole host.
if grep -q "couldn't trace process" <<<"$LOGS"; then
    # The error has no PID; it follows the "instrumenting process" line of its process.
    echo "WARNING: OBI could not trace some processes:"
    awk "/instrumenting process/ { last = \$0 }
         /couldn't trace process/ { if (last != \"\") print last; print; last = \"\" }" <<<"$LOGS"
fi

# These leave tracing running, with less detail.
if grep -q 'unable to attach java agent to process' <<<"$LOGS"; then
    echo "WARNING: OBI could not attach its Java agent to some processes; they are traced with less detail:"
    grep 'unable to attach java agent to process' <<<"$LOGS"
fi
# Java and Node.js injections run one at a time, and a Node.js one whose inspector
# doesn't open takes about 5 seconds, so some results can land after this check.
if NODE=$(grep -E "couldn't attach NodeJS injector|skipping Node.js agent injection|unable to capture stable node injection target" <<<"$LOGS"); then
    echo "WARNING: OBI did not inject its Node.js agent into some processes; they are traced with less detail:"
    echo "$NODE"
    echo "More may follow; check with: journalctl -u otel-collector | grep -E \"NodeJS injector|skipping Node.js|node injection target\""
fi
if grep -q 'context propagation is disabled' <<<"$LOGS"; then
    echo "WARNING: OBI turned off trace propagation on this kernel, so traces are not linked across hosts."
fi

# Some OBI failures are only logged at debug level, and there is no positive
# health signal, so a missing attempt can't be told apart from a silent failure.
if ! grep -q 'instrumenting process' <<<"$LOGS"; then
    echo ""
    echo "WARNING: OBI has not picked up any process yet. Either no selected process"
    echo "is running, or eBPF tracing failed silently. Start the app if it isn't running."
    echo ""
fi

echo "Otel-collector service started!"
echo "To confirm tracing, send a request to a selected app and look for its trace in OpenObserve."
