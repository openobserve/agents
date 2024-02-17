#!/bin/bash

sudo systemctl stop otel-collector
sudo systemctl disable otel-collector
sudo rm /etc/systemd/system/otel-collector.service
sudo systemctl daemon-reload
sudo systemctl reset-failed
sudo rm -f /usr/local/bin/otelcol-contrib
sudo rm -f /etc/otel-config.yaml
sudo userdel --force --remove openobserve-agent
sudo groupdel openobserve-agent


