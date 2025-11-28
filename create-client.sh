#!/bin/bash
# create-client.sh - WireGuard Client Creation

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

# Check WireGuard
command -v wg >/dev/null || error "WireGuard not installed"

# Configuration
WG_INTERFACE="wg0"
WG_SERVER_CONFIG="/etc/wireguard/$WG_INTERFACE.conf"
WG_CLIENTS_DIR="/etc/wireguard/clients"
WG_NET="10.8.0"
WG_PORT="51820"
SERVER_PUBLIC_KEY_FILE="/etc/wireguard/server_public.key"
SERVER_PUBLIC_IP_FILE="/etc/wireguard/server_public_ip.txt"

# Check files
[[ -f $WG_SERVER_CONFIG ]] || error "Server config not found: $WG_SERVER_CONFIG"
[[ -f $SERVER_PUBLIC_KEY_FILE ]] || error "Server public key not found"
[[ -f $SERVER_PUBLIC_IP_FILE ]] || error "Server IP file not found"

SERVER_PUBLIC_KEY=$(cat $SERVER_PUBLIC_KEY_FILE)
PUBLIC_IP=$(cat $SERVER_PUBLIC_IP_FILE)
ENDPOINT="$PUBLIC_IP:$WG_PORT"

# Get next available IP
get_next_ip() {
    local used_ips=($(grep -oP "AllowedIPs = $WG_NET\.\K\d+" $WG_SERVER_CONFIG 2>/dev/null | sort -n || true))
    for i in {2..254}; do
        if [[ ! " ${used_ips[@]} " =~ " ${i} " ]]; then
            echo $i
            return
        fi
    done
    error "No available IPs"
}

# Get client name
if [[ -z $1 ]]; then
    echo "🔐 WireGuard Client Creator"
    echo "=========================="
    echo ""
    echo "Usage: $0 <client-name> [ip-suffix]"
    echo "Example: $0 laptop 5"
    echo ""
    exit 1
fi

CLIENT_NAME=$1
CLIENT_IP_SUFFIX=${2:-}

echo "🔐 Creating client: $CLIENT_NAME"
echo "================================"

mkdir -p $WG_CLIENTS_DIR

# Determine client IP
if [[ -n $CLIENT_IP_SUFFIX ]]; then
    if grep -q "AllowedIPs = $WG_NET\.$CLIENT_IP_SUFFIX/32" $WG_SERVER_CONFIG; then
        error "IP $WG_NET.$CLIENT_IP_SUFFIX already in use"
    fi
else
    CLIENT_IP_SUFFIX=$(get_next_ip)
fi

CLIENT_IP="$WG_NET.$CLIENT_IP_SUFFIX"

log "Assigned IP: $CLIENT_IP"

echo ""
ask "Server endpoint (default: $ENDPOINT):"
read -p "> " custom_endpoint

if [[ -n "$custom_endpoint" ]]; then
    ENDPOINT="$custom_endpoint"
fi

echo ""
ask "Route all traffic through VPN? (Y/n):"
read -p "> " route_all
route_all=${route_all:-y}

echo ""
log "Client configuration:"
echo "Name: $CLIENT_NAME"
echo "IP: $CLIENT_IP"
echo "Endpoint: $ENDPOINT"
if [[ "$route_all" =~ ^[Yy]$ ]]; then
    echo "Traffic: All traffic through VPN"
else
    echo "Traffic: VPN + Private network only"
fi
echo ""

ask "Create client? (Y/n):"
read -p "> " confirm
[[ "$confirm" =~ ^[Nn]$ ]] && exit 0

log "Generating keys..."
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)
CLIENT_PRESHARED_KEY=$(wg genpsk)

# Create client config
CLIENT_CONFIG_FILE="$WG_CLIENTS_DIR/$CLIENT_NAME.conf"

if [[ "$route_all" =~ ^[Yy]$ ]]; then
    ALLOWED_IPS="0.0.0.0/0"
else
    ALLOWED_IPS="10.8.0.0/24, 10.10.1.0/24"
fi

cat > $CLIENT_CONFIG_FILE << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $ALLOWED_IPS
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF

# Create private-network-only config as well (backup option)
cat > $WG_CLIENTS_DIR/$CLIENT_NAME-private-only.conf << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = 10.8.0.0/24, 10.10.1.0/24
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF

log "Adding to server..."

# Add to server config
cat >> $WG_SERVER_CONFIG << EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# Reload WireGuard
log "Reloading configuration..."
wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE)

# Generate QR code for mobile
log "✅ Client created!"

echo ""
if command -v qrencode >/dev/null 2>&1; then
    echo "📱 QR Code (for mobile import):"
    echo "==============================="
    qrencode -t ansiutf8 < $CLIENT_CONFIG_FILE 2>/dev/null || echo "QR code generation failed"
    echo ""
fi

echo "📄 Configuration File:"
echo "======================"
cat $CLIENT_CONFIG_FILE

echo ""
echo "📊 Server Status:"
wg show

echo ""
log "🎉 Done! Client configuration created successfully."
echo ""
echo "📂 Configuration files:"
echo "   Main config: $CLIENT_CONFIG_FILE"
echo "   Private network only: $WG_CLIENTS_DIR/$CLIENT_NAME-private-only.conf"
echo ""
echo "📋 How to use:"
echo "   1. Copy the configuration to your WireGuard client"
echo "   2. Or scan the QR code with WireGuard mobile app"
echo "   3. Import and connect!"
