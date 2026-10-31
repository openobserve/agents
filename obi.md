# eBPF tracing and network flows on Linux (OBI)

The Linux install script ([linux/install.sh](linux/install.sh)) can also trace the
applications on a host, with no code changes and no SDK, and report the bytes the
host sends to and receives from other networks (see [Network flows](#network-flows)).
It uses OBI (OpenTelemetry eBPF Instrumentation), which runs inside the collector the
script already installs, as its `obi` receiver.

Tracing is off by default and turned on per host with `--trace-*` flags. The
`obi` receiver is at **alpha** stability in otelcol-contrib 0.163.1 (OBI v0.15.2):
span names and attributes can still change between collector releases.

## Quick start

Download `install.sh` as shown in the [README](README.md#install), then:

```bash
# Trace whatever serves on port 8080
sudo ./install.sh <URL> <AUTH_KEY> --trace-ports 8080

# Trace an app by executable path, and report it as "checkout"
sudo ./install.sh <URL> <AUTH_KEY> --trace-exe '/opt/checkout/*' --service-name checkout

# Trace a Python app by its command line (its executable is just python3)
sudo ./install.sh <URL> <AUTH_KEY> --trace-cmd '*reports.py*'
```

Then send a request to the app and look for its trace in OpenObserve. To turn
tracing off, re-run the script without the `--trace-*` flags.

## Requirements

- Linux on amd64 or arm64, kernel 5.8 or later (or a RHEL-family 4.18 kernel
  with the eBPF backports), with kernel BTF (`/sys/kernel/btf/vmlinux` or one of libbpf's fallback paths).
  OBI checks both and the install fails if either is missing.
- systemd.
- **The collector runs as root while tracing or network flows are on.** Loading
  eBPF programs, attaching to other users' processes and injecting the Java and
  Node.js agents need root-level privileges (see [Why root](#why-root)). Without
  them it runs as the unprivileged `openobserve-agent` user, as before.

Windows and macOS are not supported.

## What gets traced

OBI traces a process only if a flag selects it (see
[Choosing what to trace](#choosing-what-to-trace)) and the process sends or
receives requests in a supported protocol: HTTP/1.x, HTTP/2, gRPC, SQL (MySQL,
PostgreSQL, MSSQL), Redis, MongoDB, Kafka, NATS, AMQP 1.0, MQTT and more. It
reads requests at the kernel socket layer, so plain-text traffic is recognised
the same way from any language. For most protocols, TLS traffic is captured
through OpenSSL and Go TLS hooks, without decryption; MQTT, NATS and AMQP are
captured only in plain text.

| Runtime | What you get | Caveats |
|---|---|---|
| **Go** | Best coverage. Also hooks Go's own libraries (net/http, gRPC, database/sql, Redis and Kafka clients) and tracks context across goroutines. | Secure Boot's lockdown disables part of it. |
| **Java** | OBI injects its Java agent at runtime; follows thread pools and virtual threads. | No agent (network-level spans only) for JVMs started with `-XX:+DisableAttachMechanism` or `-Xrs`, unless they also set `-XX:+StartAttachListener`. |
| **Node.js** | Injected through the inspector, which OBI opens by sending the process SIGUSR1; follows async calls. | No agent (network-level spans only) for apps with their own SIGUSR1 handler, unless the inspector is already open. See [Limitations](#limitations). |
| **Python** | asyncio context tracked on CPython 3.9–3.14. | Free-threaded builds unsupported. |
| **Rust, C, C++** | Plain-text traffic, and TLS through OpenSSL. | TLS from other libraries (rustls, statically linked TLS) is probably not visible. |

Each incoming request produces a server span, which can have "in queue" and
"processing" children, and each outgoing call a client span. Not captured:

- **Processes no flag selects**, including client-only processes (cron jobs,
  queue consumers, scripts) that a port flag misses because they use ephemeral
  ports. Their calls still show up as server spans on the other end, if that
  server is traced.
- **Work that isn't a supported request**: batch jobs with no network calls,
  CPU-only work, custom binary protocols.
- **Function-level detail.** Spans are per request, not per function as with an
  SDK.

## Traces across services

When one traced service calls another over HTTP or gRPC, both appear in one
trace, whether they run on the same host or on different hosts. Across hosts this
needs plain-text traffic, or a Go caller (see below):

- **On the same host**, OBI sees both ends of the connection and links them
  without touching the traffic.
- **Across hosts**, OBI adds a W3C `traceparent` header to the outgoing request,
  and OBI on the receiving host reads it. Both hosts need tracing on, and both
  services must be selected. The header is also read when
  it comes from an app instrumented with an OpenTelemetry SDK, so OBI's spans
  join that app's traces.

What this means for your apps:

- **Outgoing plain-text HTTP requests from traced processes carry an extra
  `traceparent` header**, also to destinations that aren't traced (W3C Trace
  Context, which servers ignore unless they use it). Go apps get the header on
  HTTPS requests too, since OBI hooks Go's HTTP library before encryption (not
  under Secure Boot's lockdown).
- **HTTPS from other runtimes is not linked across hosts.** OBI only sees
  encrypted bytes there, so it can't add the header. Those calls start a new
  trace on the receiving host. (OBI can carry the context in a custom TCP option
  instead, `context_propagation: tcp`, but load balancers and proxies can strip
  it or reset the connection, so the script doesn't enable it.)

## Choosing what to trace

There is no "trace everything" option: name what to trace.

| Flag | Traces processes… |
|---|---|
| `--trace-ports 80,443,8000-8999` | using one of these local ports (repeatable) |
| `--trace-exe '/opt/myapp/*'` | whose executable path matches the glob (repeatable) |
| `--trace-cmd '*reports.py*'` | whose command line matches the glob (repeatable). Use it for interpreted apps, whose executable is just `python3`, `node` or `java` |
| `--service-name NAME` | Not a selector: reports every traced process as `service.name=NAME` (see [Service names](#service-names)) |

Quote globs so the shell doesn't expand them. Globs may not contain `,`, `{` or
`}`.

Things to know when choosing:

- **Ports match more than servers.** A process matches if it holds *any* socket on
  one of the ports, including outgoing connections. Ports below Linux's ephemeral
  range (32768–60999 by default) behave as expected; ranges reaching into it can
  also match client processes, and a range like `1-65535` matches almost
  everything with network activity.
- **Globs match more than the app.** In testing, `--trace-cmd '*http.server*'`
  also matched the installer's own `sudo` and `bash` (their arguments contained
  the pattern), and `--trace-exe '/usr/bin/python3*'` also matched Ubuntu's
  `unattended-upgrade-shutdown`. Make globs as specific as the app allows.
- **Child processes are selected with their parent.** A process started by a
  selected process (for example a pre-forked worker) is traced too, even if it
  doesn't match a flag itself.
- **Selecting broadly is invasive.** OBI injects an agent into every Java and
  Node.js process it matches.
- **Don't select apps that already send their own traces** through an
  OpenTelemetry SDK, or you may get duplicate spans. The `already-instrumented`
  rule only limits them. Once OBI sees a process make an HTTP call to a path
  ending in `/v1/traces` (or a gRPC trace export), it stops sending all of that
  process's spans, including database and outgoing calls the SDK may not
  record. This is a guess from the path: any app that calls such a path, an
  OTLP proxy for example, loses its OBI spans too, and so does an app that lets
  its users choose a URL it fetches (a webhook, for example), which hides that
  process's later activity until it restarts. This is OBI's own default; where
  that matters more than duplicates, delete the rule by hand (see [Editing the
  rules by hand](#editing-the-rules-by-hand)). Before that first call, and
  again after every restart of the app or the collector, spans may go out
  twice. The call counts over TLS where OBI can see the traffic, but not if it
  gets an error response. An app exporting through a TLS library OBI doesn't
  hook (such as rustls) keeps getting OBI spans. The rule doesn't stop OBI
  injecting its agent into a selected Java or Node.js app.
- The collector itself and Docker's `docker-proxy` are always excluded, so a
  broad selector doesn't trace the collector's own exports or duplicate container
  spans.

## Service names

**Without `--service-name`**, each app is named the way OBI names it:

1. `OTEL_SERVICE_NAME` (or `service.name` in `OTEL_RESOURCE_ATTRIBUTES`) from the
   app's environment, if set. OBI reads the running process's environment, so the
   variable must be set when the app starts; for a systemd service, add
   `Environment=OTEL_SERVICE_NAME=...` to its unit and restart it.
2. Otherwise, in a Docker container, the Compose service or container name.
3. Otherwise a name from the app's metadata: the Python project or launch target,
   the Node.js `package.json` name or entry point, the Spring Boot app name, JAR
   manifest title or JAR name.
4. Otherwise the executable name, such as `python3.12` or `node`, so several apps
   can end up under one name.

**With `--service-name NAME`**, every traced process on the host reports as `NAME`,
overriding even an app's own `OTEL_SERVICE_NAME`. Use it on hosts whose apps
don't name themselves, and leave it off where they do. Processes stay
distinguishable by `service.instance.id` (`host:pid`, or the container name,
`<compose service>.<container>` for Compose). Logs and metrics are not affected.

## Network flows

`--network-flows` makes OBI also export `obi.network.flow.bytes` (queried in
OpenObserve as `obi_network_flow_bytes`): bytes the host sends and receives, for any
TCP or UDP protocol, whether or not the process is traced. It works with or without
the `--trace-*` flags; on its own, OBI instruments no process.

```bash
# The same list on every host; each host labels its own flows with it
sudo ./install.sh <URL> <AUTH_KEY> --network-flows '10.0.1.5/32=web1,10.0.1.6/32=web2,10.0.2.0/24=db,0.0.0.0/0=other'
```

The flag takes a list of `CIDR` or `CIDR=NAME` entries (repeatable). Each flow is
labelled `src_cidr` and `dst_cidr` with the name of the narrowest entry that contains
its source and destination address (the CIDR itself when unnamed). An address no
entry contains leaves the label empty; a `0.0.0.0/0` (and `::/0`) entry names the
rest. Names may contain letters, digits, `.`, `_` and `-`.

**The list is what gives flows an identity.** Without Kubernetes, OBI labels flows
only with `direction`, and addresses, ports and reverse-DNS names are off by
default; the receiver's config v2 can't turn them on (attribute selection is a
standalone-only section). So name each host with a `/32` entry for a host-to-host
map, or name subnets for a coarser one.

Labels:

| Label | Values |
|---|---|
| `src_cidr`, `dst_cidr` | Name of the narrowest matching entry, or empty |
| `direction` | `request` (from the side that opened the connection), `response`, or `unknown` (UDP, TCP connections already open when the collector started, and part of a busy new connection) |
| `host_name`, `host_id` | The host that reported the flow, not an end of it (plus the cloud attributes, as for host metrics) |

For example, bytes per second from each named source to each destination:

```promql
max by (src_cidr, dst_cidr) (sum by (src_cidr, dst_cidr, host_name) (rate(obi_network_flow_bytes[5m])))
```

Things to know:

- **`direction` needs the connection's start.** OBI decides it from the TCP
  handshake (SYN, SYN-ACK), so a connection that was already open when the
  collector started, such as a keepalive pool to a back end, is `unknown` until it
  closes and is reopened. Filtering on `direction="request"` misses such an edge
  entirely. Even a busy new TCP connection is only mostly labelled: in tests
  1.3-3.4% of its bytes were `unknown`. The query above doesn't filter on it.
- **Traffic between two hosts that both run the agent is reported twice**, once by
  each host (two `host_name` values). Hence `max` above, which avoids double
  counting when either entry is a single host that runs the agent, since its report
  carries the whole total. It isn't byte-exact: the two hosts' counts differ by up
  to a few percent depending on the setup (headers, offload), and `max` takes the
  larger. Where only one side runs the agent and its entry covers several hosts,
  each host reports only its share: use
  `sum` instead. Where both entries cover several agent hosts, neither query is
  right (`max` undercounts, `sum` about doubles).
- **Loopback traffic is counted** unless both ends have the same address. For
  example 127.0.0.1 to 127.0.0.53 (a local DNS stub) appears; add
  `127.0.0.0/8=loopback` to tell it apart.
- **A flow series idle for about 6 minutes is dropped** and restarts from 0 when
  traffic resumes. `rate()` and `increase()` handle this, but subtracting two raw
  readings can go negative.
- The number of series grows with the pairs of entries that talk, not with the
  number of addresses, so wide entries such as `0.0.0.0/0` are safe.

## What the installer checks

**Before replacing anything.** With tracing flags, the script checks the new
configuration with the new collector binary (`otelcol-contrib validate`). This
runs OBI's own checks for kernel version, BTF and privileges, and rejects bad
flag values. If it fails, the script prints the error and exits, and the
installed collector, its config and the running service are left as they were.
The same check runs with `--network-flows`, and also rejects a malformed CIDR.

**After restarting.** With tracing or network flows on, the script waits for the
collector to report it is ready (up to 90 seconds), then 10 seconds more, checks it
stayed up, and scans its log for OBI errors. (Without either it only checks that the
service is running, as before.)

- **The collector crashed, didn't become ready within 90 seconds, or OBI as a
  whole failed to start** (`Unable to load eBPF watcher for process events`,
  `cant start process tracer`): the script **stops and disables the collector**,
  prints its last log lines, and exits with an error. Logs and metrics stop too,
  deliberately, so the failure doesn't go unnoticed. Either re-run without the
  `--trace-*` and `--network-flows` flags, or fix the cause (usually privileges or
  kernel support) and re-run with them; both turn the collector back on.
- **Some processes couldn't be traced** (`couldn't trace process`), **or are
  traced with less detail**: OBI logged that it couldn't attach its Java agent,
  didn't inject its Node.js agent, or turned off trace propagation on this
  kernel (see [Limitations](#limitations)). Only messages logged before the
  check runs are caught. The script
  prints a warning and finishes normally, since other processes, logs and
  metrics keep working.
- **With `--network-flows`, OBI didn't log `Flows agent successfully started`**:
  the script stops and disables the collector, as above. OBI logs why only at
  debug level, and the failure stops tracing too.
- **No selected process was picked up yet**: the script prints a warning and
  finishes normally. Usually the app isn't running yet, which is fine; it is
  traced once it starts. See also [Limitations](#limitations).

Once installed, if the host later loses what OBI needs (for example a kernel
without BTF), the collector fails at start and keeps restarting, and logs and
metrics stop until the script is re-run without the eBPF flags.

## Editing the rules by hand

Anything beyond the flags (regular expressions, languages, combined conditions)
is done by editing `receivers.obi` in `/etc/otel-config.yaml` and running
`systemctl restart otel-collector`, which also restarts logs and metrics. A
re-run of the install script overwrites hand edits.

The script generates OBI's config v2 format, for example:

```yaml
receivers:
  obi:
    version: "2.0"
    safety:
      enforce_system_capabilities: true
    engine:
      propagation:
        context_propagation: headers # traceparent header on outgoing HTTP
    policy:
      default_action: exclude        # only what a rule includes is traced
      match_order: first_match_wins
    rules:
      - action: exclude
        name: infra
        match:
          process:
            exe_path_glob: ['*/otelcol-contrib', '*/docker-proxy']
      - action: exclude
        name: already-instrumented   # apps that export their own traces
        match:
          process:
            exports_otlp:
              port: 4317
              protocol: protobuf
      - action: include
        name: ports
        match:
          process:
            open_ports: '80,443,8080'
      - action: include
        name: exe
        match:
          process:
            exe_path_glob: ['/opt/myapp/*']
```

Process conditions available in a rule (conditions in one rule must all match):

| Condition | Matches | Example |
|---|---|---|
| `open_ports` | Any local socket on these ports (see above) | `'80,443,8000-8999'` |
| `exe_path_glob` / `exe_path_regex` | Full executable path | `['/opt/*/bin/*']` |
| `cmd_args_glob` / `cmd_args_regex` | Command-line arguments | `['*gunicorn*']` |
| `language_glob` / `language_regex` | Detected runtime: `go`, `java`, `dotnet`, `python`, `ruby`, `nodejs`, `rust`, `cpp`, `php`, `generic` | `['java', 'nodejs']` |
| `containers_only` | Only processes inside containers | `true` |
| `exports_otlp` | Processes seen exporting their own traces; exclude rules only, as the rule's only condition | `{port: 4317, protocol: protobuf}` |

There is no condition for a systemd unit or cgroup; use the executable path or
command line.

Rules for editing:

- **Exclude rules come first.** OBI rejects an exclude rule placed after an
  include rule.
- **Use globs or regexes, not both.** The generated rules use globs, so added
  rules must too, or all of them must be rewritten as regexes.
- **Keep the `infra` exclusion**, and `already-instrumented` unless you have
  decided against it (see [Choosing what to trace](#choosing-what-to-trace)).
  With a `rules` section present, OBI drops its built-in exclusions, and would
  otherwise trace the collector itself and send spans for apps that export
  their own.
  `exports_otlp` must be the only condition in its rule. HTTP exports to any
  port are matched by their path; the port is only a fallback for some gRPC
  exports.
- Unknown keys are rejected, so a typo fails at start rather than silently
  disabling a rule.

## Limitations

- **Some OBI failures go unnoticed by the installer.** If OBI can't start its
  process discovery, it logs the error only at debug level, and the collector
  keeps running without tracing. The installer can't tell this apart from "the
  app isn't running yet", so it only warns. Failures later in the collector's
  life are logged without stopping it. Confirm tracing by sending a request to a
  selected app and finding its trace in OpenObserve.
- **HTTPS calls between hosts are not linked into one trace**, except from Go
  apps (see [Traces across services](#traces-across-services)).
- **Propagation can be off or partial.** On kernels with a known socket bug
  that OBI can't work around, it turns propagation off and logs `context
  propagation is disabled` (the installer warns). On kernels before 6.4,
  keep-alive connections opened before the collector started carry no header
  until the app reconnects.
- **OBI can trigger a Node.js app's own SIGUSR1 handler.** Before sending
  SIGUSR1, OBI looks for an app handler in the Node.js runtime. Where it can't
  (for example Node.js builds that link libuv as a shared library, such as
  Ubuntu's `nodejs` package), it instead searches the app's `.js`, `.ts`, `.mjs`
  and `.cjs` files for `SIGUSR1` in quotes. The search skips directories named
  like dependencies, build output or system folders (`node_modules`, `dist`,
  `build`, `lib`, `srv` and others) wherever they appear, including the app's
  own directory. A handler the search misses (in a dependency, in compiled
  output, in a `lib/` folder, or with a name built at run time) runs whenever
  OBI sends the signal: each time the app or the collector starts, including on
  every re-run of the installer. The app gets no agent either, and the
  installer warns if the failure is logged during its check. What the handler
  does is up to the app: in testing, apps that only logged kept serving. On
  these builds, don't select apps whose SIGUSR1 handler does something you
  don't want triggered, such as a heap dump or a shutdown. Conversely, a quoted
  `SIGUSR1` anywhere the search reads stops injection, even if it isn't a
  handler; only lines that start with a comment are ignored.
- No context propagation for database, messaging or cache protocols.
- Connections and prepared statements opened before OBI starts may lack query
  text or method names.
- OBI shares the collector's memory limit, and changing what is traced restarts
  the whole collector, briefly pausing logs and metrics.
- A collector upgrade also upgrades OBI, which may rename spans and attributes.
- **Network flows can under-count some transfers.** Short and 6-second bursts
  were counted fully in later tests (Linux and Kubernetes), but some slower,
  rate-limited multi-second transfers were undercounted by roughly 5% in one
  host's view. The likely cause is a race in OBI's flow-map drain, which discards
  entries whose start time predates its last read
  (`pkg/internal/netolly/ebpf/flow_map_reader_batch.go`).
- Off a cloud, a tracing or network flows install takes about 45 seconds: the installer waits for
  the collector to be ready, and its cloud metadata lookups time out first
  (about 5 seconds per pipeline).

## Design notes

For contributors. Paths refer to the OBI source at v0.15.2, the version bundled in
otelcol-contrib 0.163.1.

- **In the existing collector, not a separate service.** One unit, one config, one
  binary; tracing adds the `obi` receiver and a traces pipeline
  (`obi -> resourcedetection, resource/hostname, [resource/service_name] ->
  memory_limiter, batch -> otlphttp/openobserve`). The cost is that an OBI
  start-up failure takes logs and metrics down with it.
- **Opt-in, explicit selectors only.** Alpha stability, telemetry changes between
  releases and root access argue against enabling it for everyone, and the way
  `open_ports` matches makes any default selector far too broad.
- **Config v2 only.** In receiver mode OBI reads its config only from the
  collector YAML (`collector/config_linux.go`); the `OTEL_EBPF_*` environment
  variables are read only by standalone OBI. v2 is the proposed 1.0 format and
  rejects unknown keys. Nothing deprecated is used.
- <a id="why-root"></a>**Why root.** OBI needs `CAP_BPF`, `CAP_PERFMON`,
  `CAP_SYS_PTRACE`, `CAP_DAC_READ_SEARCH`, `CAP_CHECKPOINT_RESTORE` and
  `CAP_NET_RAW`, and in practice `CAP_SYS_ADMIN` (many distro kernels require it
  for uprobes, and Debian and Ubuntu set `perf_event_paranoid` above what
  `CAP_PERFMON` covers). Injection needs more: for Java it switches to the JVM's
  user (`CAP_SETUID`, `CAP_SETGID`, plus `CAP_SYS_CHROOT` for containers;
  `pkg/internal/jvmtools/jvm/cmd.go`), and for Node.js it signals other users'
  processes (`CAP_KILL`). With all of that the user is root in all but name, and
  older systemd versions reject capability names they don't know, such as
  `CAP_BPF`.
- **Fail hard, no fallback.** OBI's kernel and BTF checks run when the
  collector builds its pipelines, which `validate` also does, so the installer
  doesn't duplicate them. `safety.enforce_system_capabilities: true` makes
  missing capabilities fail too instead of running degraded; as root they are
  always present, so it matters only where root is restricted (for example in a
  container). The binary is staged next to the installed one for this check,
  since `/tmp` may be mounted `noexec`.
- **Detecting failures after restart.** OBI starts in the background, after the
  collector's cloud detectors time out (about 5 seconds per pipeline off a
  cloud), so with tracing the installer waits for the collector's `Everything is
  ready` line rather than a fixed time; installs without tracing keep the single
  `is-active` check. Some OBI start-up errors are logged only at debug
  level (`pkg/instrumenter/instrumenter.go`); fixing that needs the receiver to
  log them at error level or report them through component status.
- **Service name in the collector.** `--service-name` adds a standard `resource`
  processor that upserts `service.name` in the traces pipeline. OBI's own
  per-selector naming (v1 layout) is deprecated with no v2 replacement. Overriding
  only names that look auto-derived isn't possible: OBI doesn't export whether a
  name was derived.
- **Context propagation: `headers`.** OBI's default is `disabled`, which links
  services only on the same host (OBI's "black-box" correlation of the two ends
  of a local connection). Separate traces per host make a distributed system
  hard to follow, so the script sets `engine.propagation.context_propagation:
  headers`: OBI's `sk_msg` program adds a `traceparent` header to outgoing
  plain-text HTTP/1 requests and HTTP/2 streams, Go's HTTP library hooks add it
  for Go (including TLS), and incoming headers are read. `tcp` is not used: a
  custom TCP option (kind 25) on an established connection is dropped by L7
  proxies and load balancers, and some middleboxes reset the connection (see
  OBI's `devdocs/context-propagation.md`).
- **Network flows: one flag, CIDR names as identity.** `--network-flows` adds
  `network.capture.enabled: true`, `network.capture.selection.cidrs` from the flag,
  and `metrics.features: [network]` to the receiver, and a `metrics/obi` pipeline
  (`obi -> resourcedetection, resource/hostname -> memory_limiter, batch ->
  otlphttp/openobserve`). The explicit feature list keeps OBI from also sending
  request rate, error and latency metrics for traced processes. Flow labels without
  Kubernetes are `direction` only (`pkg/export/attributes/attr_defs.go`,
  `networkAttributes`); CIDR labels are on by default once a CIDR is configured
  (`networkCIDR`, enabled in `pkg/instrumenter/instrumenter.go`
  `attributeGroups`), and `attributes.select` lives in the `enrich` section, which
  receiver config rejects (`internal/config/schema/schema.go`, `ValidateReceiver`).
  A bare flag without CIDRs would report little more than the host metrics'
  `system.network.io`, so the flag requires the list. Capture uses OBI's default
  `socket_filter` source: one raw socket that sees every interface, loopback
  included (OBI's `lo` exclusion applies only to the `tc` source), deduplicated
  across interfaces. With no `--trace-*` flag the receiver keeps only its exclude rules,
  so application instrumentation doesn't start (`pkg/obi/config.go`, `Enabled`).
  Capture needs fewer capabilities (`CAP_BPF`, `CAP_NET_RAW`, `CAP_PERFMON`, and
  `CAP_SYS_RESOURCE` before 5.11; `pkg/obi/os.go`), but the collector still runs
  as root: older systemd rejects `CAP_BPF` (see [Why root](#why-root)), and
  RHEL-family 4.18 kernels need `CAP_SYS_ADMIN` instead. A network setup failure ends OBI's whole run, tracing
  included, and is logged only at debug level (`pkg/instrumenter/instrumenter.go`),
  hence the required success line.

## Tested on

Collector 0.163.1 on an Ubuntu 24.04 arm64 VM (kernel 6.8), sending to
OpenObserve, with Python HTTP servers as the traced apps. Covered: flag checks;
installs with and without tracing; each flag, including `--service-name`; apps
setting their own `OTEL_SERVICE_NAME`; the collector excluding itself; a rejected
configuration leaving the install untouched; a crashing collector being stopped
and disabled, then recovering on re-run; and turning tracing off.

Traces across services were tested with a front-end service on one VM calling a
back end on a second VM over HTTP: every request formed one trace spanning both
hosts, with the back end's server span parented to the front end's client span.
The back end received the `traceparent` header whether or not it was traced
itself, and none with propagation set to `disabled`. With `disabled`, two
services on the same host were still linked into one trace.

Java (OpenJDK 21), Node.js (Ubuntu's `nodejs` 18) and Go (1.22) HTTP servers
were tested on the same kind of VM, under steady load for 6 minutes:

- **Java and Node.js** got their agents injected, stayed up, and showed no
  measurable change in latency. The JVM's memory grew by about 30 MB for the
  agent, and the JDK printed `A Java agent has been loaded dynamically` to the
  app's own stderr. A JVM started with `-XX:+DisableAttachMechanism` got no
  agent, the installer warned, and its server spans still arrived.
- **A Node.js app with its own SIGUSR1 handler** was skipped when the handler
  was written as `process.on('SIGUSR1', …)` in the app's own files, and still
  got network-level spans. With the handler in `dist/`, in `node_modules/`, or
  with the signal name built at run time, the handler ran on each collector
  start, no agent was injected, and the app kept serving (see
  [Limitations](#limitations)). The installer's warning listed only the
  failures logged within its 10-second check.
- **Traces across services**, all over plain-text HTTP: Go to Go, Go to Java
  and Node.js to Go each formed one trace on every request, with the
  `traceparent` header arriving at the back end.

An app instrumented with the OpenTelemetry SDK, exporting over plain HTTP, got
OBI spans only for its first 1.5 seconds of traffic, before its first export,
and again for under 2 seconds after a collector restart. An uninstrumented app
beside it was traced throughout.

Network flows were tested on 2026-10-29 on Multipass VMs on a Mac mini (arm64):

- **Ubuntu 24.04 (kernel 6.8) and 22.04 (5.15)**: installs succeeded, with
  `Flows agent successfully started` logged about 22 seconds after start, before
  the installer's check. HTTP and Redis traffic between two hosts arrived with the
  right `src_cidr` and `dst_cidr` names, each edge reported by both hosts, each
  report within about 5% of the bytes sent (a 52.4 MB Redis burst: 55.05 MB and
  52.5 MB; 31.5 MB of HTTP: 32.9 MB and 30.5 MB). Loopback was counted only
  between different addresses (127.0.0.1 to 127.0.0.2, and the DNS stub), not
  127.0.0.1 to itself. Combined with `--trace-ports`, both spans and flows
  arrived, and no RED metrics. On 5.15 the combined mode logs OBI's `TCP socket
  iterator disabled` warning (see [Limitations](#limitations)).
- **Ubuntu 20.04 (5.4)**: rejected by the pre-flight validate (`kernel version
  5.4 not supported. Minimum required version is 5.8`). A fresh install left no
  unit, config or binary; an existing working install was left untouched (same
  PID, and unchanged config, binary and unit).
- The collector used 260-320 MB RSS and about 1% CPU; flows added about 25-75 MB.
- **Across two hosts** (4 VMs, 22.04 on 5.15 and 24.04 on 6.8; nginx to an API to
  Postgres and Redis): every edge was named correctly. Of 524.3 MB of payload the
  sender reported 4.9-5.3% more, the receiver 0.15% more; the ACK side matched exactly.

Not yet tested: .NET apps, Go's header injection over TLS, cloud hosts, and kernels
where OBI fails or turns propagation off after start-up.

## References

- OBI documentation: https://opentelemetry.io/docs/zero-code/obi/
- OBI source: https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation
- Collector distribution including OBI:
  https://github.com/open-telemetry/opentelemetry-collector-releases/blob/v0.163.1/distributions/otelcol-contrib/manifest.yaml
