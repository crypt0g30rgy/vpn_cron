#!/bin/bash
set -euo pipefail

# LOG_FILE="/var/log/openvpn.log"

# Log file based on timestamp
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="/var/log/vpn-cron/openvpn_$TIMESTAMP.log"
VPN_DIR="/etc/openvpn"
# Allow overriding the credential file path via env (useful when mounting elsewhere)
CRED_FILE="${VPN_CRED_FILE:-$VPN_DIR/vpn-credentials.txt}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Starting ProtonVPN with rotation, kill switch, and DNS leak protection..."

# If an env file exists at /opt/.env (image convention), load it so DISCORD_WEBHOOK_URL or other vars are available
if [[ -f /opt/.env ]]; then
  set -a
  # shellcheck disable=SC1090
  source /opt/.env
  set +a
fi
# Fail early if credentials file missing (helps debugging when mounting/packaging)
if [[ ! -f "$CRED_FILE" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] | ERROR: credentials file $CRED_FILE not found"
  # If a webhook is available, try to alert
  if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    payload=$(jq -n --arg content "[$timestamp] ERROR: VPN credentials missing at $CRED_FILE" '{content:$content}')
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null || true
  fi
  exit 1
fi

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
/usr/sbin/iptables -F
/usr/sbin/iptables -P OUTPUT ACCEPT
/usr/sbin/iptables -P INPUT ACCEPT
/usr/sbin/iptables -P FORWARD ACCEPT

# Allow connection to VPN server during handshake
/usr/sbin/iptables -A OUTPUT -d "$VPN_IP" -j ACCEPT
/usr/sbin/iptables -A OUTPUT -o lo -j ACCEPT
/usr/sbin/iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Run OpenVPN in background
/usr/sbin/openvpn --config "$VPN_CONFIG" \
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
/usr/sbin/iptables -F
/usr/sbin/iptables -P OUTPUT DROP
/usr/sbin/iptables -A OUTPUT -o tun0 -j ACCEPT
/usr/sbin/iptables -A OUTPUT -o lo -j ACCEPT
/usr/sbin/iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
/usr/sbin/iptables -A OUTPUT -d "$VPN_IP" -j ACCEPT

# Now that tun0 is up, optionally use ProtonVPN DNS to avoid leaks
echo "nameserver 10.8.8.1" > /etc/resolv.conf || true

# Confirm current IP (and detect DNS resolution issues)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] | Current IP:"
IPINFO_OUT=$(curl -sS --max-time 10 https://ipinfo.io 2>&1) || true
if echo "$IPINFO_OUT" | grep -qi "Could not resolve host\|Name or service not known\|Temporary failure in name resolution"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] | DNS resolution failed when querying ipinfo.io: upgrading resolv.conf to public DNS (1.1.1.1, 8.8.8.8)"
  echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf || true
  # retry
  IPINFO_OUT=$(curl -sS --max-time 10 https://ipinfo.io 2>&1) || true
fi

if [[ -n "$IPINFO_OUT" ]]; then
  echo "$IPINFO_OUT" | sed -n '1,200p'
else
  echo "Could not fetch IP info (curl DNS issue)."
fi

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
