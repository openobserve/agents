# macOS agent

Installs the OpenTelemetry collector (`otelcol-contrib`) as a LaunchDaemon and ships
host metrics, standard log files, and the macOS unified log to OpenObserve.

## Install

```bash
curl -O https://raw.githubusercontent.com/openobserve/agents/main/mac/install.sh && chmod +x install.sh && sudo ./install.sh {URL} {authorization_token}
```

e.g.

```bash
curl -O https://raw.githubusercontent.com/openobserve/agents/main/mac/install.sh && chmod +x install.sh && sudo ./install.sh https://api.openobserve.com/api/your_org/ cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
```

Re-running the installer is safe, it replaces the existing install.

## Uninstall

```bash
curl -O https://raw.githubusercontent.com/openobserve/agents/main/mac/uninstall.sh && chmod +x uninstall.sh && sudo ./uninstall.sh
```

## What gets collected

| Signal | Source | Stream |
| --- | --- | --- |
| Metrics | `host_metrics`: cpu, disk, filesystem, load, memory, network, paging, processes | default |
| Logs | Log files under `/var/log`, `/Library/Logs`, `/usr/local/var/log`, `/opt/homebrew/var/log` | default |
| Logs | macOS unified log (`log stream`) | `macos_unified` |

Per-user logs in `~/Library/Logs` are not collected by default. There is a commented
out `include` entry for them in `/etc/otel-config.yaml` if you want them.

## How the unified log is collected

The unified log is a binary store, not a file the collector can tail, so `log stream`
is used as a bridge. A second LaunchDaemon runs
`/opt/openobserve-collector/macos-unified-log.sh`, which is effectively:

```bash
/usr/bin/log stream --style ndjson --no-backtrace | nc 127.0.0.1 54525
```

and the collector picks it up on a loopback-only listener:

```yaml
receivers:
  tcp_log/macos:
    listen_address: 127.0.0.1:54525
    operators:
      - type: json_parser
```

Each event is parsed out of NDJSON, its `timestamp` becomes the record timestamp,
`messageType` is mapped to a severity (`Default`/`Info` to info, `Error` to error,
`Fault` to fatal), and `eventMessage` becomes the log body. Everything else
(`processImagePath`, `subsystem`, `category`, `processID`, ...) is kept as attributes.

### Reducing volume

The unified log is noisy, on the order of a hundred events per second on an idle
laptop even at the default level. To trim it, edit the knobs at the top of
`/opt/openobserve-collector/macos-unified-log.sh`:

```bash
LEVEL="default"    # default | info | debug, each step up is a large jump in volume
PREDICATE=""       # e.g. 'messageType == error OR subsystem BEGINSWITH "com.mycompany"'
```

then apply the change:

```bash
sudo launchctl kickstart -k system/ai.openobserve.macos-unified-log
```

## Files and services

| Path | Purpose |
| --- | --- |
| `/opt/openobserve-collector/otelcol-contrib` | Collector binary |
| `/opt/openobserve-collector/macos-unified-log.sh` | Unified log bridge |
| `/etc/otel-config.yaml` | Collector config |
| `/Library/Logs/openobserve-collector/` | Agent's own stdout/stderr |
| `/Library/LaunchDaemons/ai.openobserve.otelcol-contrib.plist` | Collector service |
| `/Library/LaunchDaemons/ai.openobserve.macos-unified-log.plist` | Bridge service |

Both services run as root with `KeepAlive`, so they start at boot and restart on failure.

## Troubleshooting

Check that both services are loaded:

```bash
sudo launchctl print system/ai.openobserve.otelcol-contrib | head -20
sudo launchctl print system/ai.openobserve.macos-unified-log | head -20
```

Check the agent's own logs:

```bash
tail -f /Library/Logs/openobserve-collector/collector.err
tail -f /Library/Logs/openobserve-collector/unified-log.err
```

Confirm the collector is listening for the bridge:

```bash
sudo lsof -nP -iTCP:54525 -sTCP:LISTEN
```

Restart after a config change:

```bash
sudo launchctl kickstart -k system/ai.openobserve.otelcol-contrib
```

### The agent's own logs are deliberately quiet

`collector.err` is normally near empty. launchd never rotates
`StandardOutPath`/`StandardErrorPath` and keeps the file open, so a renaming rotator
such as `newsyslog` would not help here, the collector would simply keep writing to
the rotated file. The size is bounded at the source instead, via
`service::telemetry::logs` in `/etc/otel-config.yaml`: warn and above only, with
repeated messages sampled. Left unbounded, an unreachable endpoint logs a retry per
batch, which measures around 42 MiB per day.

An empty `collector.err` therefore means the agent is healthy, not that logging is
broken. To debug, raise the level temporarily:

```bash
sudo sed -i '' 's/level: warn/level: info/' /etc/otel-config.yaml
sudo launchctl kickstart -k system/ai.openobserve.otelcol-contrib
```

Set it back to `warn` when you are done, otherwise the file will grow.
