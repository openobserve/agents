#!/bin/bash

sudo systemctl stop otel-collector
sudo systemctl disable otel-collector
sudo rm /etc/systemd/system/otel-collector.service
sudo systemctl daemon-reload
sudo systemctl reset-failed

