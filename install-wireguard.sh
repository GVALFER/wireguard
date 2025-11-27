#!/bin/bash
# install.sh - Minimal WireGuard Server Installation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ask() { echo -e "${BLUE}[Q]${NC} $1"; }

# Check root
[[ $EUID -ne 0 ]] && error "Run as root"

echo "🚀 WireGuard Installation"
echo "========================"
echo ""

# Auto-detect NICs
log "Detecting network interfaces..."

# Get physical interfaces (exclude virtual ones)
INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp|en[0-9])' | grep -v '@' | sort))

if [ ${#INTERFACES[@]} -eq 0 ]; then
    error "No physical network interfaces found"
fi

# Show detected interfaces
echo "Found ${#INTERFACES[@]} NIC(s):"
for i in "${!INTERFACES[@]}"; do
    IFACE=${INTERFACES[$i]}
    STATUS=$(ip link show $IFACE | grep -o "state [A-Z]*" | cut -d' ' -f2)
    IP=$(ip -4 addr show $IFACE | grep -oP 'inet \K[\d.]+/\d+' | head -1)
    IP_DISPLAY=${IP:-"no IP"}
    echo "$((i+1))) $IFACE ($STATUS, $IP_DISPLAY)"
done
echo ""

# Auto-configuration
if [ ${#INTERFACES[@]} -eq 1 ]; then
    log "Single NIC detected - VPN-only mode"
    NETWORK_1_INTERFACE=${INTERFACES[0]}
    NETWORK_2_INTERFACE=""
    VPN_MODE="internet-only"
elif [ ${#INTERFACES[@]} -ge 2 ]; then
    log "Multi-NIC detected - Full routing mode"
    NETWORK_1_INTERFACE=${INTERFACES[0]}
    NETWORK_2_INTERFACE=${INTERFACES[1]}
    VPN_MODE="full-routing"

    echo "Auto-configuration:"
    echo "NETWORK_1 (internet): $NETWORK_1_INTERFACE"
    echo "NETWORK_2 (private): $NETWORK_2_INTERFACE"
fi

echo ""
ask "Continue with auto-configuration? (Y/n):"
read -p "> " CONTINUE
CONTINUE=${CONTINUE:-y}
[[ ! $CONTINUE =~ ^[Yy]$ ]] && { log "Installation cancelled"; exit 0; }

# Quick configuration
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
PRIVATE_NET="10.10.1.0/24"

echo ""
log "Configuration:"
echo "Interface: $WG_INTERFACE"
echo "Port: $WG_PORT"
echo "VPN Network: $WG_NET"
echo "Private Network: $PRIVATE_NET"
echo ""

# Install
log "Installing WireGuard..."
apt update -qq
apt install -y wireguard wireguard-tools qrencode >/dev/null 2>&1

# Enable forwarding
log "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf 2>/dev/null || true
sysctl -p >/dev/null 2>&1

# Generate keys
log "Generating server keys..."
cd /etc/wireguard
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)

# Create config
log "Creating server configuration..."

if [ "$VPN_MODE" = "internet-only" ]; then
    # Single NIC - internet only
    POSTUP_RULES="iptables -t nat -A POSTROUTING -s $WG_NET -o $NETWORK_1_INTERFACE -j MASQUERADE; iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT"
    POSTDOWN_RULES="iptables -t nat -D POSTROUTING -s $WG_NET -o $NETWORK_1_INTERFACE -j MASQUERADE; iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT"
else
    # Multi NIC - full routing
    POSTUP_RULES="iptables -t nat -A POSTROUTING -s $WG_NET -d $PRIVATE_NET -o $NETWORK_2_INTERFACE -j MASQUERADE; iptables -t nat -A POSTROUTING -s $WG_NET -o $NETWORK_1_INTERFACE -j MASQUERADE; iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT"
    POSTDOWN_RULES="iptables -t nat -D POSTROUTING -s $WG_NET -d $PRIVATE_NET -o $NETWORK_2_INTERFACE -j MASQUERADE; iptables -t nat -D POSTROUTING -s $WG_NET -o $NETWORK_1_INTERFACE -j MASQUERADE; iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT"
fi

cat > $WG_INTERFACE.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
PostUp = $POSTUP_RULES
PostDown = $POSTDOWN_RULES

# Clients will be added here

EOF

chmod 600 $WG_INTERFACE.conf

# Save config for client script
mkdir -p clients
cat > server.env << EOF
WG_INTERFACE=$WG_INTERFACE
WG_PORT=$WG_PORT
WG_NET=$WG_NET
WG_SERVER_IP=$WG_SERVER_IP
NETWORK_1_INTERFACE=$NETWORK_1_INTERFACE
NETWORK_2_INTERFACE=$NETWORK_2_INTERFACE
PRIVATE_NET=$PRIVATE_NET
SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
VPN_MODE=$VPN_MODE
EOF

# Start service
log "Starting WireGuard..."
systemctl enable wg-quick@$WG_INTERFACE >/dev/null 2>&1
systemctl start wg-quick@$WG_INTERFACE

# Configure firewall
ufw allow $WG_PORT/udp >/dev/null 2>&1 || true

# Verify
log "Verifying installation..."
sleep 2
if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
    echo ""
    log "✅ WireGuard installed successfully!"
    echo ""
    echo "📋 Server Information:"
    echo "======================"
    echo "Public Key: $SERVER_PUBLIC_KEY"
    echo "Listen Port: $WG_PORT"
    echo "VPN Network: $WG_NET"
    if [ "$VPN_MODE" = "full-routing" ]; then
        echo "Private Network: $PRIVATE_NET"
    fi
    echo ""
    wg show
    echo ""
    log "🔧 Next: Run './create-client.sh <name>' to add clients"
else
    error "WireGuard failed to start"
fi
