# ProtonVPN Docker Setup

A lightweight, auto-restarting ProtonVPN container with a built-in **kill switch**, **health monitoring**, and optional dependent services for secure networking.

---

## 🚀 Features

- 🔒 Secure VPN tunnel (OpenVPN)
- 🤱 Automatic **kill switch** using `iptables`
- ♻️ Auto-restart & self-healing health checks
- 🌍 Configurable ProtonVPN `.ovpn` profiles
- 📝 Simple logging and external IP display
- 🕒 Cron-friendly for background jobs

---

## 📁 Folder Structure

```bash
.
├── Dockerfile
├── docker-compose.yml
├── start-vpn.sh
├── vpn-credentials.txt
├── openvpn/
│   ├── us.protonvpn.udp.ovpn
│   ├── uk.protonvpn.tcp.ovpn
│   └── ...
└── logs/
```

---

## ⚙️ Configuration

### 1️⃣ Create your credentials file

Create `vpn-credentials.txt`:

```text
your_protonvpn_username
your_protonvpn_password
```

> ⚠️ Keep this file safe! Do **not** commit it to GitHub.

### 2️⃣ Add ProtonVPN configuration

Download ProtonVPN `.ovpn` config files from your account dashboard and place them inside the `openvpn/` folder.

Example:

```text
openvpn/us.protonvpn.udp.ovpn
openvpn/nl.protonvpn.tcp.ovpn
```

### 3️⃣ Start the container

```bash
docker compose up -d
```

Check logs:

```bash
docker logs -f protonvpn
```

You should see:

```text
VPN tunnel is up!
VPN ready and protected.
```

---

## 🔍 Healthcheck

The container includes a health monitor that verifies:

- the VPN interface (`tun0`) exists, and  
- a valid external IP is reachable.

Check health status:

```bash
docker inspect --format='{{json .State.Health}}' protonvpn | jq
```

Output example:

```json
{
  "Status": "healthy",
  "Log": [
    { "Output": "VPN OK (89.238.155.151)" }
  ]
}
```

---

## 🧹 Example: Dependent Service

To ensure your app only runs when the VPN is healthy, you can add a dependent container:

```yaml
  myapp:
    image: alpine
    command: ["sh", "-c", "curl ifconfig.me && sleep infinity"]
    depends_on:
      protonvpn:
        condition: service_healthy
    network_mode: "service:protonvpn"
```

This forces `myapp` to share the VPN’s network stack and only start **after** ProtonVPN is connected.

---

## 🚫 Stopping the VPN

```bash
docker compose down
```

---

## 🔧 Troubleshooting

| Issue                   | Fix                                                                                  |
| ----------------------- | ------------------------------------------------------------------------------------ |
| `Server poll timeout`   | Try a different `.ovpn` file (region or TCP/UDP variant)                             |
| `Cannot resolve host`   | Add fallback DNS servers in `docker-compose.yml`                                     |
| `Auth Username` prompt  | Ensure `auth-user-pass /etc/openvpn/vpn-credentials.txt` is inside your `.ovpn` file |
| File permission warning | Use a writable volume for `/etc/openvpn` or remove chmod line in container           |

## 📝 License

MIT © 2025
