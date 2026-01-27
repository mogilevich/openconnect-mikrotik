# ============================================
# OpenConnect VPN Container Setup for MikroTik
# ============================================
#
# Basic container setup for OpenConnect VPN
#
# REQUIREMENTS:
# - RouterOS 7.4+
# - Container package installed
# - Container mode enabled: /system/device-mode/update container=yes
#
# ============================================

# ==== SETTINGS ====

:local vpnServer "vpn.example.com:8443"
:local vpnUser "myuser"
:local vpnPassword "mypassword"

# Optional: certificate pin (if verification fails)
:local vpnServercert ""

:local containerDNS "8.8.8.8"
:local containerIP "172.18.0.2"
:local containerGW "172.18.0.1"
:local containerNet "172.18.0.0/24"

# ==== END SETTINGS ====


:put "Creating container network..."

/interface/veth add name=veth-vpn address="$containerIP/24" gateway=$containerGW
/interface/bridge add name=br-containers
/ip/address add address="$containerGW/24" interface=br-containers
/interface/bridge/port add bridge=br-containers interface=veth-vpn
/ip/firewall/nat add chain=srcnat action=masquerade src-address=$containerNet comment="NAT for containers"

:put "Creating environment variables..."

/container/envs remove [find where list=openconnect]
/container/envs add list=openconnect key=OC_SERVER value=$vpnServer
/container/envs add list=openconnect key=OC_USER value=$vpnUser
/container/envs add list=openconnect key=OC_PASSWORD value=$vpnPassword

:if ([:len $vpnServercert] > 0) do={
    /container/envs add list=openconnect key=OC_SERVERCERT value=$vpnServercert
}

/container/config set registry-url=https://registry-1.docker.io tmpdir=/tmp

:put ""
:put "============================================"
:put "Setup complete!"
:put "============================================"
:put ""
:put "Next steps:"
:put "1. Upload openconnect-mikrotik-arm64.tar to router"
:put "2. Add container:"
:put "   /container add file=openconnect-mikrotik-arm64.tar interface=veth-vpn envlist=openconnect root-dir=openconnect dns=$containerDNS start-on-boot=yes logging=yes"
:put "3. Start: /container start 0"
:put "4. Check logs: /container/log print"
:put ""
