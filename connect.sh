#!/bin/sh
# OpenConnect VPN Client for MikroTik with NAT/Routing/DNS

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

cleanup() { 
    log "Stopping..."
    killall dnsmasq 2>/dev/null
    kill $(cat /run/oc.pid 2>/dev/null) 2>/dev/null
    exit 0
}
trap cleanup TERM INT

log "Starting OpenConnect..."
log "Server: $OC_SERVER"
log "User: $OC_USER"
log "MTU: ${OC_MTU:-1300}"

while true; do
    log "Connecting to $OC_SERVER..."
    echo "$OC_PASSWORD" | $CMD
    
    if [ $? -eq 0 ]; then
        log "Connected!"
        
        # Wait for tun interface
        sleep 2
        
        # Setup NAT
        setup_nat
        
        # Setup DNS proxy
        setup_dns
        
        while [ -f /run/oc.pid ] && kill -0 $(cat /run/oc.pid) 2>/dev/null; do
            sleep 10
        done
        log "Disconnected!"
        killall dnsmasq 2>/dev/null
    else
        log "Connection failed!"
    fi
    
    rm -f /run/oc.pid
    sleep ${OC_RECONNECT_DELAY:-5}
done
