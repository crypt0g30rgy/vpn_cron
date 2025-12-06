#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/rotate-vpn.log"
VPN_PID_FILE="/var/run/openvpn.pid"
START_SCRIPT="/usr/local/bin/start-vpn.sh"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] | rotate-vpn: starting" >> "$LOG_FILE"

# If openvpn is running, kill it gracefully
if [[ -f "$VPN_PID_FILE" ]]; then
  pid=$(cat "$VPN_PID_FILE" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] | rotate-vpn: killing openvpn (pid $pid)" >> "$LOG_FILE"
    kill "$pid" || true
    sleep 2
  fi
fi

# Remove pid file if exists
rm -f "$VPN_PID_FILE" || true

# Start VPN script to pick a new config
if [[ -x "$START_SCRIPT" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] | rotate-vpn: invoking $START_SCRIPT" >> "$LOG_FILE"
  # Start in background so rotate script returns quickly
  "$START_SCRIPT" &
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] | rotate-vpn: start script not found or not executable" >> "$LOG_FILE"
fi

exit 0
