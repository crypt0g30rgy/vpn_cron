#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/openvpn.log"
VPN_DIR="/etc/openvpn"
CRED_FILE="$VPN_DIR/vpn-credentials.txt"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Starting ProtonVPN with rotation, kill switch, and DNS leak protection..."

# Pick a random .ovpn config
mapfile -t configs < <(find "$VPN_DIR" -maxdepth 1 -type f -name "*.ovpn" | sort)
if [ "${#configs[@]}" -eq 0 ]; then
  echo "No .ovpn configs found in $VPN_DIR" >&2
  exit 1
fi
VPN_CONFIG="${configs[RANDOM % ${#configs[@]}]}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Selected config: $VPN_CONFIG"

# Parse VPN server
VPN_SERVER=$(grep -m1 '^remote ' "$VPN_CONFIG" | awk '{print $2}')
VPN_IP=$(getent ahosts "$VPN_SERVER" | awk '{print $1; exit}')
echo "[$(date '+%Y-%m-%d %H:%M:%S')] | VPN Server: $VPN_SERVER ($VPN_IP)"

# Make sure we start clean
iptables -F
iptables -P OUTPUT ACCEPT
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT

# Allow connection to VPN server during handshake
iptables -A OUTPUT -d "$VPN_IP" -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Optional: use ProtonVPN DNS (prevents leaks)
echo "nameserver 10.8.8.1" > /etc/resolv.conf || true

# Run OpenVPN in background
openvpn --config "$VPN_CONFIG" \
  --auth-user-pass "$CRED_FILE" \
  --pull-filter ignore "auth-token" \
  --writepid /var/run/openvpn.pid \
  --daemon \
  --log "$LOG_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Waiting for VPN tunnel (tun0)..."

# Wait for tun0 interface
for i in {1..40}; do
  if ip a show tun0 &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] | VPN connected!"
    break
  fi
  sleep 2
done

if ! ip a show tun0 &>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] | VPN connection failed. Logs:"
  tail -n 30 "$LOG_FILE"
  exit 1
fi

# Enable kill switch AFTER successful connection
echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Applying kill switch rules..."
iptables -F
iptables -P OUTPUT DROP
iptables -A OUTPUT -o tun0 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d "$VPN_IP" -j ACCEPT

# Confirm current IP
echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Current IP:"
curl -s https://ipinfo.io || echo "Could not fetch IP info (curl DNS issue)."

echo "[$(date '+%Y-%m-%d %H:%M:%S')] | VPN ready and traffic locked."

# Monitor connection, auto-reconnect if tun0 drops
while true; do
  sleep 20
  if ! ip a show tun0 &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] | VPN dropped! Reconnecting..."
    kill "$(cat /var/run/openvpn.pid 2>/dev/null)" 2>/dev/null || true
    exec "$0"  # restart script to rotate configs again
  fi
done