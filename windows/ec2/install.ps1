receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
      disk:
      filesystem:
      load:
      memory:
      network:
      paging:
      # process: # can cause errors on some Windows configurations, disabled by default

  windowsperfcounters/processor:
    collection_interval: 30s
    metrics:
      processor.time:
        description: Active and idle time of the processor
        unit: "%"
        gauge:
    perfcounters:
      - object: "Processor"
        instances: "*"
        counters:
          - name: "% Processor Time"
            metric: processor.time
            attributes:
              state: active

  windowsperfcounters/memory:
    collection_interval: 30s
    metrics:
      bytes.committed:
        description: Number of bytes committed to memory
        unit: By
        gauge:
    perfcounters:
      - object: Memory
        counters:
          - name: Committed Bytes
            metric: bytes.committed

  windowseventlog/application:
    channel: application
  windowseventlog/security:
    channel: security
  windowseventlog/setup:
    channel: setup
  windowseventlog/system:
    channel: system

processors:
  resourcedetection/system:
    detectors: ["system"]
    system:
      hostname_sources: ["os"]
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 15
  batch:
    send_batch_size: 10000
    timeout: 10s

extensions:
  zpages: {}

exporters:
  otlphttp/openobserve:
    endpoint: $URL
    headers:
      Authorization: "Basic $AUTH_KEY"
      stream-name: windows

service:
  extensions: [zpages]
  pipelines:
    metrics:
      receivers: [hostmetrics, windowsperfcounters/processor, windowsperfcounters/memory]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
    logs:
      receivers: [windowseventlog/application, windowseventlog/security, windowseventlog/setup, windowseventlog/system]
      processors: [resourcedetection/system, memory_limiter, batch]
      exporters: [otlphttp/openobserve]
