#!/bin/bash
sudo systemctl status xray nginx --no-pager
if systemctl list-unit-files --type=service | grep -q '^haproxy.service'; then
  sudo systemctl status haproxy --no-pager
fi
