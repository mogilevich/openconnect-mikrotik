# ============================================
# VPN Network Setup for MikroTik
# ============================================
#
# Creates VLAN with WiFi for VPN clients
# Traffic and DNS go through OpenConnect container
#
# REQUIREMENTS:
# - OpenConnect container configured and running (172.18.0.2)
# - bridge-trunk exists with vlan-filtering=yes
#
# ============================================

# ==== SETTINGS ====

:local vlanId 16
:local vlanName "vlan16-openconnect"
:local trunkBridge "bridge-trunk"

:local wifiName "wifi16"
:local wifiMaster "wifi2"
:local wifiSSID "VPN-Network"
:local wifiPassword "YourSecurePassword123"

:local vpnNetwork "192.168.16.0/24"
:local vpnGateway "192.168.16.1"
:local vpnPoolStart "192.168.16.10"
:local vpnPoolEnd "192.168.16.254"

:local containerIP "172.18.0.2"
:local containerNetwork "172.18.0.0/24"

# ==== END SETTINGS ====


:put "============================================"
:put "Creating VPN client network..."
:put "============================================"

# VLAN on bridge-trunk
:put "Creating VLAN $vlanId on $trunkBridge..."
/interface/bridge/vlan add bridge=$trunkBridge tagged=$trunkBridge vlan-ids=$vlanId

# VLAN interface
:put "Creating VLAN interface $vlanName..."
/interface/vlan add interface=$trunkBridge name=$vlanName vlan-id=$vlanId

# WiFi
:put "Creating WiFi interface $wifiName..."
/interface/wifi add name=$wifiName master-interface=$wifiMaster \
    configuration.ssid=$wifiSSID \
    security.authentication-types=wpa2-psk,wpa3-psk \
    security.passphrase=$wifiPassword

# WiFi to bridge as untagged
:put "Adding WiFi to bridge with VLAN $vlanId..."
/interface/bridge/port add bridge=$trunkBridge interface=$wifiName pvid=$vlanId
/interface/bridge/vlan set [find where vlan-ids=$vlanId and bridge=$trunkBridge] untagged=$wifiName

# IP on VLAN
:put "Configuring IP on $vlanName..."
/ip/address add address="$vpnGateway/24" interface=$vlanName

# DHCP - DNS points to container for VPN DNS
:put "Configuring DHCP with container DNS..."
/ip/pool add name=pool-vpn-clients ranges="$vpnPoolStart-$vpnPoolEnd"
/ip/dhcp-server add name=dhcp-vpn-clients interface=$vlanName address-pool=pool-vpn-clients lease-time=1h disabled=no
/ip/dhcp-server/network add address=$vpnNetwork gateway=$vpnGateway dns-server=$containerIP

# Routing table
:put "Configuring routing..."
/routing/table add name=vpn-routing fib

# Route through container
/ip/route add dst-address=0.0.0.0/0 gateway=$containerIP routing-table=vpn-routing

# Mangle
:put "Configuring mangle..."
/ip/firewall/mangle add chain=prerouting src-address=$vpnNetwork action=mark-routing new-routing-mark=vpn-routing passthrough=no comment="Route VPN clients through container"

# Firewall
:put "Configuring firewall..."
/ip/firewall/filter add chain=forward src-address=$vpnNetwork dst-address=$containerNetwork action=accept comment="VPN clients to container" place-before=0
/ip/firewall/filter add chain=forward src-address=$containerNetwork dst-address=$vpnNetwork action=accept comment="Container to VPN clients" place-before=0

:put ""
:put "============================================"
:put "VPN Network configured!"
:put "============================================"
:put ""
:put "VLAN: $vlanId ($vlanName)"
:put "Network: $vpnNetwork"
:put "Gateway: $vpnGateway"
:put "DNS: $containerIP (VPN DNS proxy)"
:put "WiFi SSID: $wifiSSID"
:put ""
:put "Clients will use VPN DNS for internal domains"
:put "============================================"
