#!/bin/bash
# create-client.sh - WireGuard Client Creation Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration variables
WG_INTERFACE="wg0"
WG_SERVER_CONFIG="/etc/wireguard/$WG_INTERFACE.conf"
WG_CLIENTS_DIR="/etc/wireguard/clients"
WG_NET="10.8.0"
WG_PORT="51820"
SERVER_PUBLIC_KEY_FILE="/etc/wireguard/server_public.key"
SERVER_PUBLIC_IP_FILE="/etc/wireguard/server_public_ip.txt"

# Functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${BLUE}[Q]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Check if WireGuard is installed
if ! command -v wg &> /dev/null; then
    error "WireGuard is not installed. Run install-wireguard.sh first."
fi

# Check if server config exists
if [[ ! -f $WG_SERVER_CONFIG ]]; then
    error "Server configuration not found: $WG_SERVER_CONFIG"
fi

# Get server public key
if [[ ! -f $SERVER_PUBLIC_KEY_FILE ]]; then
    error "Server public key not found: $SERVER_PUBLIC_KEY_FILE"
fi

SERVER_PUBLIC_KEY=$(cat $SERVER_PUBLIC_KEY_FILE)

# Get server public IP
if [[ -f $SERVER_PUBLIC_IP_FILE ]]; then
    SERVER_PUBLIC_IP=$(cat $SERVER_PUBLIC_IP_FILE)
else
    log "Public IP file not found, detecting..."
    SERVER_PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
    if [[ -z "$SERVER_PUBLIC_IP" ]]; then
        error "Failed to detect server public IP"
    fi
    echo "$SERVER_PUBLIC_IP" > $SERVER_PUBLIC_IP_FILE
fi

ENDPOINT="$SERVER_PUBLIC_IP:$WG_PORT"

# Get client name
if [[ -z $1 ]]; then
    echo "🔐 WireGuard Client Creator"
    echo "=========================="
    echo ""
    echo "Usage: $0 <client-name> [ip-suffix]"
    echo "Example: $0 john-laptop 5"
    echo "This will create client with IP 10.8.0.5"
    echo ""
    exit 1
fi

CLIENT_NAME=$1
CLIENT_IP_SUFFIX=${2:-}

log "🔐 Creating client: $CLIENT_NAME"
echo "================================"

# Create clients directory if not exists
mkdir -p $WG_CLIENTS_DIR

# Function to get next available IP
get_next_ip() {
    local used_ips=($(grep -oP "AllowedIPs = $WG_NET\.\K\d+" $WG_SERVER_CONFIG 2>/dev/null | sort -n || true))
    local server_ip=1  # Server uses .1

    for i in {2..254}; do
        if [[ ! " ${used_ips[@]} " =~ " ${i} " ]]; then
            echo $i
            return
        fi
    done

    error "No available IPs in range"
}

# Determine client IP
if [[ -n $CLIENT_IP_SUFFIX ]]; then
    # Check if IP is already in use
    if grep -q "AllowedIPs = $WG_NET\.$CLIENT_IP_SUFFIX/32" $WG_SERVER_CONFIG; then
        error "IP $WG_NET.$CLIENT_IP_SUFFIX is already in use"
    fi
    CLIENT_IP_SUFFIX=$CLIENT_IP_SUFFIX
else
    CLIENT_IP_SUFFIX=$(get_next_ip)
fi

CLIENT_IP="$WG_NET.$CLIENT_IP_SUFFIX"

log "Assigned IP: $CLIENT_IP"

# Ask for confirmation and endpoint
echo ""
info "Server endpoint (default: $ENDPOINT): "
read -r custom_endpoint

if [[ -n "$custom_endpoint" ]]; then
    ENDPOINT="$custom_endpoint"
fi

echo ""
log "Client configuration:"
echo "Name: $CLIENT_NAME"
echo "IP: $CLIENT_IP"
echo "Endpoint: $ENDPOINT"
echo "Routes: 0.0.0.0/0 (Full VPN)"
echo ""

info "Create client? (Y/n): "
read -r confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    log "Client creation cancelled."
    exit 0
fi

log "Generating keys..."
# Generate client keys
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)
CLIENT_PRESHARED_KEY=$(wg genpsk)

# Create client configuration file
CLIENT_CONFIG_FILE="$WG_CLIENTS_DIR/$CLIENT_NAME.conf"

cat > $CLIENT_CONFIG_FILE << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF

# Create client config for IPMI access only (alternative)
cat > $WG_CLIENTS_DIR/$CLIENT_NAME-ipmi-only.conf << EOF
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

# Add client to server configuration
cat >> $WG_SERVER_CONFIG << EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# Reload WireGuard configuration
log "Reloading WireGuard configuration..."
wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE)

# Generate QR code
log "✅ Client created!"
echo ""
echo "📱 QR Code:"
echo "==========="
qrencode -t ansiutf8 < $CLIENT_CONFIG_FILE 2>/dev/null || echo "QR code generation failed (qrencode not available)"

echo ""
echo "📄 Configuration file:"
echo "======================"
cat $CLIENT_CONFIG_FILE

echo ""
log "📂 Files created:"
echo "Full VPN: $CLIENT_CONFIG_FILE"
echo "IPMI Only: $WG_CLIENTS_DIR/$CLIENT_NAME-ipmi-only.conf"
echo ""

# Show current status
log "📊 Current server status:"
wg show

echo ""
log "🎉 Done! Client file: $CLIENT_CONFIG_FILE"

echo ""
echo "🗑️  To remove this client:"
echo "========================"
echo "1. Remove the [Peer] section for $CLIENT_NAME from $WG_SERVER_CONFIG"
echo "2. Run: wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE)"
echo "3. Delete: $CLIENT_CONFIG_FILE"
