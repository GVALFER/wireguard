#!/bin/bash
# create-client.sh - Minimal WireGuard Client Creation

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ask() { echo -e "${BLUE}[Q]${NC} $1"; }

# Check root
[[ $EUID -ne 0 ]] && error "Run as root"

# Load config
[[ ! -f /etc/wireguard/server.env ]] && error "Server not configured. Run install-wireguard.sh first"
source /etc/wireguard/server.env

# Check arguments
[[ -z $1 ]] && { echo "Usage: $0 <client-name>"; exit 1; }

CLIENT_NAME=$1
WG_CONFIG="/etc/wireguard/$WG_INTERFACE.conf"
CLIENT_DIR="/etc/wireguard/clients"
CLIENT_FILE="$CLIENT_DIR/$CLIENT_NAME.conf"

# Check if client exists
[[ -f $CLIENT_FILE ]] && error "Client '$CLIENT_NAME' already exists"

echo "🔐 Creating client: $CLIENT_NAME"
echo "================================"
echo ""

# Get next IP
get_next_ip() {
    local used_ips=($(grep -oP "AllowedIPs = ${WG_NET%.*}\.\K\d+" $WG_CONFIG 2>/dev/null | sort -n))
    for i in {2..254}; do
        if [[ ! " ${used_ips[@]} " =~ " ${i} " ]]; then
            echo $i
            return
        fi
    done
    error "No available IPs"
}

CLIENT_IP_SUFFIX=$(get_next_ip)
CLIENT_IP="${WG_NET%.*}.$CLIENT_IP_SUFFIX"

log "Assigned IP: $CLIENT_IP"

# Minimal questions
ask "Server endpoint (domain:port, default: your-server.com:$WG_PORT):"
read -p "> " ENDPOINT
ENDPOINT=${ENDPOINT:-your-server.com:$WG_PORT}

if [ "$VPN_MODE" = "full-routing" ]; then
    ask "Route all traffic through VPN? (Y/n):"
    read -p "> " ROUTE_ALL
    ROUTE_ALL=${ROUTE_ALL:-y}

    if [[ $ROUTE_ALL =~ ^[Yy]$ ]]; then
        ALLOWED_IPS="0.0.0.0/0"
    else
        ALLOWED_IPS="$WG_NET, $PRIVATE_NET"
    fi
else
    ALLOWED_IPS="0.0.0.0/0"
fi

echo ""
log "Client configuration:"
echo "Name: $CLIENT_NAME"
echo "IP: $CLIENT_IP"
echo "Endpoint: $ENDPOINT"
echo "Routes: $ALLOWED_IPS"
echo ""

ask "Create client? (Y/n):"
read -p "> " CONFIRM
CONFIRM=${CONFIRM:-y}
[[ ! $CONFIRM =~ ^[Yy]$ ]] && { log "Cancelled"; exit 0; }

# Generate keys
log "Generating keys..."
CLIENT_PRIVATE=$(wg genkey)
CLIENT_PUBLIC=$(echo $CLIENT_PRIVATE | wg pubkey)
CLIENT_PRESHARED=$(wg genpsk)

# Create client config
mkdir -p $CLIENT_DIR
cat > $CLIENT_FILE << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = $CLIENT_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED
AllowedIPs = $ALLOWED_IPS
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF

# Add to server
log "Adding to server..."
cat >> $WG_CONFIG << EOF

# Client: $CLIENT_NAME ($CLIENT_IP)
[Peer]
PublicKey = $CLIENT_PUBLIC
PresharedKey = $CLIENT_PRESHARED
AllowedIPs = $CLIENT_IP/32
EOF

# Reload server
wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE) 2>/dev/null || systemctl reload wg-quick@$WG_INTERFACE

echo ""
log "✅ Client created!"
echo ""
echo "📱 QR Code:"
echo "==========="
qrencode -t ansiutf8 < $CLIENT_FILE
echo ""

echo "📄 Configuration file:"
echo "======================"
cat $CLIENT_FILE
echo ""

log "🎉 Done! Client file: $CLIENT_FILE"
