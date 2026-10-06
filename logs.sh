#!/bin/bash
sudo journalctl -u xray -u haproxy -u nginx -f
