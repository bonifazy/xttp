#!/bin/bash
sudo systemctl restart xray nginx
if systemctl list-unit-files --type=service | grep -q '^haproxy.service'; then
  sudo systemctl restart haproxy
fi
