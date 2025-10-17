FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && \
    apt-get install -y openvpn iptables curl unzip jq dnsutils iproute2 iputils-ping netcat jq net-tools iptables && \
    rm -rf /var/lib/apt/lists/*

# Copy ProtonVPN configs
COPY ./protonvpn-configs/ /etc/openvpn/

# Copy credentials file
COPY ./vpn-credentials.txt /etc/openvpn/vpn-credentials.txt

# RUN chmod 600 /etc/openvpn/vpn-credentials.txt

# Copy VPN startup script
COPY start-vpn.sh /usr/local/bin/start-vpn.sh
RUN chmod +x /usr/local/bin/start-vpn.sh

CMD ["/usr/local/bin/start-vpn.sh"]