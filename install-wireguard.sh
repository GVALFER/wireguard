#!/bin/bash
# install-wireguard.sh - WireGuard Server Installation

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

# Detect public IP
log "Detecting public IP..."
PUBLIC_IP=""
for service in "ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "ipecho.net/plain"; do
    PUBLIC_IP=$(timeout 5 curl -s $service 2>/dev/null || true)
    if [[ $PUBLIC_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "Detected public IP: $PUBLIC_IP"
        break
    fi
done

if [[ -z "$PUBLIC_IP" ]]; then
    error "Failed to detect public IP. Check internet connection."
fi

# Auto-detect NICs
log "Detecting network interfaces..."
INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp|en[0-9])' | grep -v '@' | sort))

if [ ${#INTERFACES[@]} -eq 0 ]; then
    error "No physical network interfaces found"
fi

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
log "Configuration:"
echo "Interface: wg0"
echo "Port: 51820"
echo "VPN Network: 10.8.0.0/24"
echo "Private Network: 10.10.1.0/24"
echo "Public IP: $PUBLIC_IP"
echo ""

ask "Continue with auto-configuration? (Y/n):"
read -p "> " CONTINUE
CONTINUE=${CONTINUE:-y}
[[ ! $CONTINUE =~ ^[Yy]$ ]] && { log "Installation cancelled"; exit 0; }

# Configuration
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
PRIVATE_NET="10.10.1.0/24"

# Install packages
log "Installing packages..."
apt update -qq
apt install -y wireguard wireguard-tools qrencode >/dev/null 2>&1

# Enable forwarding
log "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf 2>/dev/null || true
sysctl -p >/dev/null 2>&1

# Generate keys
log "Generating server keys..."
mkdir -p /etc/wireguard
cd /etc/wireguard
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)

# Save public IP for client script
echo "$PUBLIC_IP" > server_public_ip.txt

# Create WireGuard config
log "Creating WireGuard configuration..."

if [ "$VPN_MODE" = "internet-only" ]; then
    POSTUP_RULES="iptables -t nat -A POSTROUTING -s $WG_NET -o $NETWORK_1_INTERFACE -j MASQUERADE; iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT"
    POSTDOWN_RULES="iptables -t nat -D POSTROUTING -s $WG_NET -o $NETWORK_1_INTERFACE -j MASQUERADE; iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT"
else
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

# Create clients directory
mkdir -p clients

# Configure firewall
log "Configuring firewall..."
ufw allow $WG_PORT/udp >/dev/null 2>&1 || true

# Start WireGuard service
log "Starting WireGuard service..."
systemctl enable wg-quick@$WG_INTERFACE >/dev/null 2>&1
systemctl start wg-quick@$WG_INTERFACE

# Verify installation
log "Verifying installation..."
sleep 3

WG_STATUS="❌"
if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
    WG_STATUS="✅"
fi

echo ""
log "🎉 Installation completed!"
echo ""
echo "📋 Server Information:"
echo "======================"
echo "Public Key: $SERVER_PUBLIC_KEY"
echo "Public IP: $PUBLIC_IP"
echo "WireGuard Port: $WG_PORT ($WG_STATUS)"
echo "VPN Network: $WG_NET"
if [ "$VPN_MODE" = "full-routing" ]; then
    echo "Private Network: $PRIVATE_NET"
fi
echo ""

wg show

echo ""
echo "🔧 Next Steps:"
echo "=============="
echo "1. Run './create-client.sh <name>' to add clients"
echo "2. Clients will receive configuration files with QR codes"
echo "3. Use './wg-manage.sh' for client management"
echo ""

if [[ "$WG_STATUS" = "✅" ]]; then
    log "✅ WireGuard running successfully!"
else
    warn "⚠️ WireGuard service may need attention"
fi
