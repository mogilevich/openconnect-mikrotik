#!/bin/sh
# OpenConnect VPN Client for MikroTik with NAT/Routing/DNS
# Supports both split-tunnel and full-tunnel modes

log() { echo "[$(date '+%H:%M:%S')] $1"; }

[ -z "$OC_SERVER" ] && { log "ERROR: Set OC_SERVER, OC_USER, OC_PASSWORD"; exit 1; }
[ -z "$OC_USER" ] && { log "ERROR: Set OC_SERVER, OC_USER, OC_PASSWORD"; exit 1; }
[ -z "$OC_PASSWORD" ] && { log "ERROR: Set OC_SERVER, OC_USER, OC_PASSWORD"; exit 1; }

# TUN device
[ -d /dev/net ] || mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200

# Enable IP forwarding
log "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Build command
CMD="openconnect --user=$OC_USER --passwd-on-stdin --non-inter --background --pid-file=/run/oc.pid"

# MTU
CMD="$CMD --mtu=${OC_MTU:-1300}"

# Server certificate
[ -n "$OC_SERVERCERT" ] && CMD="$CMD --servercert=$OC_SERVERCERT"

# Protocol
[ -n "$OC_PROTOCOL" ] && CMD="$CMD --protocol=$OC_PROTOCOL"

# Group
[ -n "$OC_GROUP" ] && CMD="$CMD --authgroup=$OC_GROUP"

# Extra arguments
[ -n "$OC_EXTRA_ARGS" ] && CMD="$CMD $OC_EXTRA_ARGS"

CMD="$CMD $OC_SERVER"

setup_policy_routing() {
    log "Setting up policy-based routing..."
    
    # Detect LAN interface (veth)
    LAN_IF=$(ip -o link show | grep 'veth' | head -1 | awk -F': ' '{print $2}' | cut -d'@' -f1)
    [ -z "$LAN_IF" ] && LAN_IF="veth-vpn"
    
    # Get LAN gateway (MikroTik)
    LAN_GW=$(ip route | grep "via.*dev $LAN_IF" | head -1 | awk '{print $3}')
    [ -z "$LAN_GW" ] && LAN_GW="172.18.0.1"
    
    # Get container IP
    CONTAINER_IP=$(ip -4 addr show dev $LAN_IF | grep inet | awk '{print $2}' | cut -d'/' -f1)
    [ -z "$CONTAINER_IP" ] && CONTAINER_IP="172.18.0.2"
    
    log "LAN interface: $LAN_IF"
    log "LAN gateway: $LAN_GW"
    log "Container IP: $CONTAINER_IP"
    
    # Client networks that connect through this container
    # These need to be routed back through veth, not through VPN
    CLIENT_NETWORKS="${OC_CLIENT_NETWORKS:-192.168.16.0/24}"
    
    log "Client networks: $CLIENT_NETWORKS"
    
    # Create routing table for LAN traffic (table 100)
    # This ensures responses to clients always go through veth-vpn
    
    # Clean up old rules
    ip rule del table 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
    
    # Add default route via LAN gateway in table 100
    ip route add default via $LAN_GW dev $LAN_IF table 100
    
    # Add rule: packets FROM client networks use table 100 for responses
    # This is handled by connection tracking, but we need explicit routes for client subnets
    
    # More importantly: add explicit routes for client networks via LAN
    # These routes have higher priority than default via tun0
    for net in $CLIENT_NETWORKS; do
        log "Adding route for client network: $net via $LAN_GW"
        ip route add $net via $LAN_GW dev $LAN_IF 2>/dev/null || \
        ip route replace $net via $LAN_GW dev $LAN_IF
    done
    
    # Also ensure the container network itself is routed correctly
    CONTAINER_NET=$(echo $CONTAINER_IP | sed 's/\.[0-9]*$/.0\/24/')
    log "Container network: $CONTAINER_NET"
    
    log "Policy routing configured"
}

setup_nat() {
    log "Setting up NAT and forwarding..."
    
    # Detect LAN interface (veth)
    LAN_IF=$(ip -o link show | grep 'veth' | head -1 | awk -F': ' '{print $2}' | cut -d'@' -f1)
    [ -z "$LAN_IF" ] && LAN_IF="veth-vpn"
    
    log "LAN interface: $LAN_IF"
    log "TUN interface: tun0"
    
    # Clear old rules
    iptables -F FORWARD 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null
    
    # Allow all forwarding
    iptables -P FORWARD ACCEPT
    
    # NAT for outgoing traffic through tun0 (VPN networks)
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    
    # NAT for outgoing traffic through veth (regular internet)
    iptables -t nat -A POSTROUTING -o $LAN_IF -j MASQUERADE
    
    log "NAT configured for tun0 and $LAN_IF"
}

setup_dns() {
    log "Setting up DNS proxy..."
    
    # Wait for vpnc-script to update resolv.conf
    sleep 1
    
    # Get DNS servers from VPN
    VPN_DNS=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -3 | tr '\n' ' ')
    
    if [ -z "$VPN_DNS" ]; then
        log "No VPN DNS found, using 8.8.8.8"
        VPN_DNS="8.8.8.8"
    fi
    
    log "VPN DNS servers: $VPN_DNS"
    
    # Stop old dnsmasq if running
    killall dnsmasq 2>/dev/null
    
    # Create dnsmasq config
    cat > /etc/dnsmasq.conf << DNSCONF
# Run as root (no user switching)
user=root

# Listen on all interfaces
listen-address=0.0.0.0
bind-interfaces

# Don't read /etc/resolv.conf
no-resolv

# Use VPN DNS servers
$(for dns in $VPN_DNS; do echo "server=$dns"; done)

# Cache DNS queries
cache-size=1000

# Don't forward plain names
domain-needed
bogus-priv
DNSCONF

    # Start dnsmasq
    dnsmasq
    
    if [ $? -eq 0 ]; then
        log "DNS proxy started on port 53"
    else
        log "Failed to start DNS proxy"
    fi
}

detect_tunnel_mode() {
    # Check if default route goes through tun0
    if ip route | grep -q "^default.*tun0"; then
        echo "full"
    else
        echo "split"
    fi
}

keep_alive() {
    log "Setting up keep-alive..."
    
    KEEPALIVE_INTERVAL=${OC_KEEPALIVE_INTERVAL:-60}
    
    log "Keep-alive: DNS lookup every ${KEEPALIVE_INTERVAL}s"
    
    # Start background keep-alive process
    (
        while true; do
            sleep $KEEPALIVE_INTERVAL
            if [ -f /run/oc.pid ] && kill -0 "$(cat /run/oc.pid 2>/dev/null)" 2>/dev/null; then
                # DNS lookup through VPN DNS (reads /etc/resolv.conf automatically)
                nslookup google.com >/dev/null 2>&1
            else
                break
            fi
        done
    ) &
    
    echo $! > /run/keepalive.pid
    log "Keep-alive started (PID: $(cat /run/keepalive.pid))"
}

cleanup() { 
    log "Stopping..."
    killall dnsmasq 2>/dev/null
    kill "$(cat /run/oc.pid 2>/dev/null)" 2>/dev/null
    kill "$(cat /run/keepalive.pid 2>/dev/null)" 2>/dev/null
    rm -f /run/keepalive.pid
    # Clean up policy routing
    ip rule del table 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

log "Starting OpenConnect..."
log "Server: $OC_SERVER"
log "User: $OC_USER"
log "MTU: ${OC_MTU:-1300}"
[ -n "$OC_CLIENT_NETWORKS" ] && log "Client networks: $OC_CLIENT_NETWORKS"

while true; do
    log "Connecting to $OC_SERVER..."
    echo "$OC_PASSWORD" | $CMD
    
    if [ $? -eq 0 ]; then
        log "Connected!"
        
        # Wait for tun interface and routes
        sleep 2
        
        # Detect tunnel mode
        TUNNEL_MODE=$(detect_tunnel_mode)
        log "Tunnel mode: $TUNNEL_MODE"
        
        # Setup policy routing (critical for full-tunnel mode)
        setup_policy_routing
        
        # Setup NAT
        setup_nat
        
        # Setup DNS proxy
        setup_dns
        
        # Setup keep-alive
        keep_alive
        
        # Show routing info
        log "=== Routing table ==="
        ip route | while read line; do log "  $line"; done
        log "===================="
        
        while [ -f /run/oc.pid ] && kill -0 "$(cat /run/oc.pid)" 2>/dev/null; do
            sleep 10
        done
        log "Disconnected!"
        killall dnsmasq 2>/dev/null
        kill "$(cat /run/keepalive.pid 2>/dev/null)" 2>/dev/null
        rm -f /run/keepalive.pid
        # Clean up policy routing
        ip rule del table 100 2>/dev/null || true
        ip route flush table 100 2>/dev/null || true
    else
        log "Connection failed!"
    fi
    
    rm -f /run/oc.pid
    sleep ${OC_RECONNECT_DELAY:-5}
done
