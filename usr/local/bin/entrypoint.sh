#!/bin/bash
set -e

# Start VPN in background if script exists
if [[ -x "/usr/local/bin/start-vpn.sh" ]]; then
  echo "Starting VPN script in background..."
  /usr/local/bin/start-vpn.sh &
else
  echo "No start-vpn.sh found or not executable"
fi

# Ensure rotation script exists at /usr/local/bin/rotate-vpn.sh (if user mounted it, that will override)
if [[ ! -x "/usr/local/bin/rotate-vpn.sh" ]]; then
  echo "/usr/local/bin/rotate-vpn.sh not present or not executable"
else
  echo "/usr/local/bin/rotate-vpn.sh is present and executable"
fi

# Check discord purge script
if [[ ! -x "/usr/local/bin/discord_purge.sh" ]]; then
  echo "/usr/local/bin/discord_purge.sh not present or not executable"
else
  echo "/usr/local/bin/discord_purge.sh is present and executable"
fi

# Ensure monitor script exists at /opt/monitor.sh (if user mounted it, that will override)
if [[ ! -x "/opt/monitor.sh" ]]; then
  echo "/opt/monitor.sh not present or not executable"
else
  echo "/opt/monitor.sh is present and executable"
fi

echo "$CRON_JOB" > /etc/cron.d/monitor-cron
# Write cron jobs: monitor every 30 minutes, rotate VPN every hour
# Logs go to separate log files based on timestamp

cat > /etc/cron.d/vpn-monitor-cron <<'CRON'
# Run monitor every 30 minutes
*/30 * * * * /opt/monitor.sh >> /var/log/vpn-cron/monitor_$(date +\%Y-\%m-\%d_\%H-\%M).log 2>&1

# Rotate VPN every hour
0 * * * * /usr/local/bin/rotate-vpn.sh >> /var/log/vpn-cron/rotate_vpn_$(date +\%Y-\%m-\%d_\%H-\%M).log 2>&1

# Purge Discord logs every 2 hours
0 */2 * * * /usr/local/bin/discord_purge.sh >> /var/log/vpn-cron/discord_purge_$(date +\%Y-\%m-\%d_\%H-\%M).log 2>&1

# Clean up logs older than 7 days daily at 3 AM
0 3 * * * find /var/log/vpn-cron/ -type f -name "*.log" -mtime +7 -delete
CRON

chmod 0644 /etc/cron.d/vpn-monitor-cron
crontab /etc/cron.d/vpn-monitor-cron || true

# Start cron in foreground
echo "Starting cron..."
cron -f
