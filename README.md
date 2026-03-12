# OpenConnect VPN Client for MikroTik

[![CI](https://github.com/mogilevich/openconnect-mikrotik/actions/workflows/ci.yml/badge.svg)](https://github.com/mogilevich/openconnect-mikrotik/actions/workflows/ci.yml)
[![Release](https://github.com/mogilevich/openconnect-mikrotik/actions/workflows/build-release.yml/badge.svg)](https://github.com/mogilevich/openconnect-mikrotik/actions/workflows/build-release.yml)

Minimal Docker container for connecting MikroTik routers to OpenConnect (ocserv) VPN servers with routing and DNS support for clients.

## Features

- ✅ ARM64 support (MikroTik hAP ax2, ax3, RB5009, etc.)
- ✅ ARM32 support (MikroTik hAP ac2, hEX, RB4011, etc.)
- ✅ AMD64 support (CHR, x86 routers)
- ✅ **Split-tunnel mode** — only VPN networks through tunnel
- ✅ **Full-tunnel mode** — all traffic through VPN
- ✅ Automatic reconnection on connection loss
- ✅ NAT and routing for clients (iptables-legacy for broad kernel compatibility)
- ✅ DNS proxy — clients use VPN DNS servers
- ✅ **Image size ~21MB** (custom build without libproxy)

## Environment Variables

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `OC_SERVER` | VPN server address with port | `vpn.example.com:8443` |
| `OC_USER` | Username | `myuser` |
| `OC_PASSWORD` | Password | `mypassword` |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `OC_CLIENT_NETWORKS` | `192.168.16.0/24` | Networks that use this VPN (space-separated) |
| `OC_SERVERCERT` | - | Server certificate pin (see below) |
| `OC_PROTOCOL` | anyconnect | Protocol: `anyconnect`, `nc`, `gp`, `pulse`, `fortinet` |
| `OC_GROUP` | - | VPN group |
| `OC_MTU` | 1300 | Tunnel MTU |
| `OC_EXTRA_ARGS` | - | Additional openconnect arguments |
| `OC_RECONNECT_DELAY` | 5 | Reconnection delay in seconds |
| `OC_KEEPALIVE_INTERVAL` | 60 | Keep-alive interval in seconds (DNS lookup to prevent idle disconnect) |

### OC_CLIENT_NETWORKS

**Important for full-tunnel mode!** This variable tells the container which networks connect through it. Without this, responses to clients won't route back correctly when VPN uses full-tunnel (default route through tun0).

```bash
# Single network
/container/envs/add list=openconnect key=OC_CLIENT_NETWORKS value="192.168.16.0/24"

# Multiple networks (space-separated)
/container/envs/add list=openconnect key=OC_CLIENT_NETWORKS value="192.168.16.0/24 192.168.17.0/24"
```

### Using OC_SERVERCERT

If server certificate fails verification (self-signed, hostname mismatch, etc.), openconnect will show an error with the pin:

```
Certificate from VPN server "vpn.example.com" failed verification.
To trust this server in future, perhaps add this to your command line:
    --servercert pin-sha256:V3cztC+H5YuAIM3T+PoUXEjy6LRfIUpgGt2dauOw/ws=
```

Add the pin:

```
/container/envs/add list=openconnect key=OC_SERVERCERT value="pin-sha256:V3cztC+H5YuAIM3T+PoUXEjy6LRfIUpgGt2dauOw/ws="
```

## Tunnel Modes

The container automatically detects which mode the VPN server uses:

### Split-tunnel Mode
VPN server pushes routes only for specific networks. Internet traffic goes directly through MikroTik.

```
ip route:
default via 172.18.0.1 dev veth-vpn       # Internet → MikroTik
10.10.0.0/16 dev tun0                      # Corporate → VPN
10.20.0.0/16 dev tun0                      # Corporate → VPN
```

### Full-tunnel Mode  
VPN server pushes default route. All traffic goes through VPN.

```
ip route:
default dev tun0                           # Everything → VPN
192.168.16.0/24 via 172.18.0.1 dev veth-vpn  # Clients → MikroTik (added by container)
```

The container automatically adds routes for `OC_CLIENT_NETWORKS` to ensure client traffic routes correctly in both modes.

## Installation

### Step 1: Prepare the Router

```bash
# Enable containers (router will reboot)
/system/device-mode/update container=yes
```

### Step 2: Configure

Edit VPN settings at the top of `mikrotik-setup.rsc` (server, user, password), upload to the router, then run:

```bash
/import file-name=mikrotik-setup.rsc
```

This creates the veth interface, bridge, network, environment variables, and firewall rules.

### Step 3: Add Container

Choose one of the options:

**Option A: Pull from GitHub Container Registry**

```bash
/container add remote-image=ghcr.io/mogilevich/openconnect-mikrotik:latest \
    interface=veth-vpn \
    envlist=openconnect \
    root-dir=openconnect \
    dns=8.8.8.8 \
    start-on-boot=yes \
    logging=yes
```

**Option B: Download pre-built .tar**

1. Download from [Releases](https://github.com/mogilevich/openconnect-mikrotik/releases/latest) for your architecture
2. Upload the `.tar` file to the router (via Files, FTP, or SCP)
3. Add container:

```bash
/container add file=openconnect-mikrotik-arm64.tar \
    interface=veth-vpn \
    envlist=openconnect \
    root-dir=openconnect \
    dns=8.8.8.8 \
    start-on-boot=yes \
    logging=yes
```

**Option C: Build locally**

```bash
./build.sh arm64   # or arm, amd64, all
```

Then upload the `.tar` and add as in Option B.

### Step 4: Start

```bash
/container start 0
```

### Step 5: VPN Network for Clients (Optional)

Edit settings at the top of `mikrotik-vpn-network.rsc` (VLAN ID, WiFi SSID/password, subnet), upload to the router, then run:

```bash
/import file-name=mikrotik-vpn-network.rsc
```

This creates:

- VLAN on bridge-trunk
- WiFi network with specified SSID and password
- DHCP with DNS through container
- Policy-based routing through VPN

## Architecture

```
Client (192.168.16.x)
    │
    ├─── DNS queries ──► Container:53 (dnsmasq) ──► VPN DNS
    │
    └─── Traffic ──► MikroTik (mangle) ──► Container (NAT)
                                            │
                                            ├─► tun0 (VPN networks / all traffic)
                                            │
                                            └─► veth-vpn (internet in split-tunnel)

Container routing (full-tunnel mode):
    default ──► tun0 (VPN)
    192.168.16.0/24 ──► veth-vpn (clients, added automatically)
```

## Monitoring

```bash
# Container status
/container print

# Logs
/container/log print

# Shell into container
/container/shell 0

# Inside container:
ip route              # routes (check for client network routes)
ip addr               # interfaces  
iptables -t nat -L -v # NAT rules
cat /etc/resolv.conf  # VPN DNS
```

## Troubleshooting

### Clients can't access anything in full-tunnel mode

Check that `OC_CLIENT_NETWORKS` is set correctly:
```bash
/container/envs print where list=openconnect
```

Inside container, verify routes:
```bash
/container/shell 0
ip route | grep 192.168.16
# Should show: 192.168.16.0/24 via 172.18.0.1 dev veth-vpn
```

### No internet for clients
Check NAT in container:
```bash
/container/shell 0
iptables -t nat -L POSTROUTING -v
# Should have MASQUERADE for tun0 and veth-vpn
```

### Internal domains not resolving for clients
Ensure DHCP provides DNS = container IP:
```bash
/ip/dhcp-server/network print
# dns-server should be 172.18.0.2
```

### SSL connection failure
- Check port in `OC_SERVER`
- Add `--verbose`:
  ```bash
  /container/envs/add list=openconnect key=OC_EXTRA_ARGS value="--verbose"
  ```

## Project Files

| File | Description |
|------|-------------|
| `Dockerfile` | Multi-stage build of openconnect without libproxy |
| `connect.sh` | Connection script with NAT, DNS proxy, and policy routing |
| `build.sh` | Build script for arm64/arm/amd64 |
| `mikrotik-setup.rsc` | Basic container setup |
| `mikrotik-vpn-network.rsc` | VLAN/WiFi setup for clients |

## Size Optimization

Image optimized to **~21MB** (was 37MB with packaged openconnect):

- Multi-stage build of openconnect from source
- Flags: `--without-libproxy --without-libpskc --without-stoken --without-gssapi --disable-nls`
- iptables-legacy backend instead of nft (smaller, better MikroTik kernel compatibility)
- Removed: nft backend, unused xtables extensions, GLib, curl, duktape, pcre2, p11-kit CLI, scanelf, etc.

## License

MIT License - see [LICENSE](LICENSE) file.
 