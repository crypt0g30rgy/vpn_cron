FROM ubuntu:22.04

# Install dependencies (including cron)
RUN apt-get update && \
    apt-get install -y cron openvpn iptables curl unzip jq dnsutils iproute2 iputils-ping netcat net-tools && \
    rm -rf /var/lib/apt/lists/*

# # Create workspace
# WORKDIR /workspace

# Ensure target dir exists so COPY works reliably
RUN mkdir -p /etc/openvpn

# Create log directory
RUN mkdir -p /var/log/vpn-cron

# Copy ProtonVPN configs
COPY ./protonvpn-configs/ /etc/openvpn/

# Copy credentials file
COPY ./vpn-credentials.txt /etc/openvpn/vpn-credentials.txt

# Copy VPN startup script
COPY start-vpn.sh /usr/local/bin/start-vpn.sh
RUN chmod +x /usr/local/bin/start-vpn.sh

# Copy rotation script
COPY ./usr/local/bin/rotate-vpn.sh /usr/local/bin/rotate-vpn.sh
RUN chmod +x /usr/local/bin/rotate-vpn.sh

# Copy Discord purge script
COPY ./usr/local/bin/discord_purge.sh /usr/local/bin/discord_purge.sh
RUN chmod +x /usr/local/bin/discord_purge.sh

# Copy monitor script as a fallback (can be overridden by mounting /opt/monitor.sh)
COPY monitor.sh /opt/monitor.sh
COPY .env /opt/.env
RUN chmod +x /opt/monitor.sh || true

# Copy entrypoint
COPY ./usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh || true

# Expose logs dir (optional)
# Note: mounting a host directory (like ./protonvpn-configs) over /etc/openvpn
# at runtime will hide any files that were copied there during build. Mount the
# credentials file explicitly in docker-compose to avoid that problem.
# VOLUME ["/workspace", "/var/log"]

VOLUME ["/var/log"]

CMD ["/usr/local/bin/entrypoint.sh"]