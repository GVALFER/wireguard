#!/bin/bash
# create-client.sh - WireGuard Client Creation with Secure Downloads

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
NGINX_PORT="8080"
SERVER_PUBLIC_KEY_FILE="/etc/wireguard/server_public.key"
SERVER_PUBLIC_IP_FILE="/etc/wireguard/server_public_ip.txt"
SERVER_SECRET_KEY_FILE="/etc/wireguard/server_secret_key.txt"
DOWNLOAD_DIR="/var/www/wireguard-dl"

# Check files
[[ -f $WG_SERVER_CONFIG ]] || error "Server config not found: $WG_SERVER_CONFIG"
[[ -f $SERVER_PUBLIC_KEY_FILE ]] || error "Server public key not found"
[[ -f $SERVER_PUBLIC_IP_FILE ]] || error "Server IP file not found"
[[ -f $SERVER_SECRET_KEY_FILE ]] || error "Server secret key not found"

SERVER_PUBLIC_KEY=$(cat $SERVER_PUBLIC_KEY_FILE)
PUBLIC_IP=$(cat $SERVER_PUBLIC_IP_FILE)
SECRET_KEY=$(cat $SERVER_SECRET_KEY_FILE)
ENDPOINT="$PUBLIC_IP:$WG_PORT"

# Function to generate secure download URL
generate_secure_url() {
    local client_name="$1"
    local expiry_hours="${2:-2}"  # Default 2 hours

    # Calculate expiration timestamp
    local expire_time=$(($(date +%s) + expiry_hours * 3600))

    # URI path for hash calculation
    local uri="/wg-dl/$expire_time/PLACEHOLDER/$client_name.conf"

    # Generate MD5 hash
    local hash_input="${expire_time}${uri} ${SECRET_KEY}"
    local secure_hash=$(echo -n "$hash_input" | md5sum | cut -d' ' -f1)

    # Final secure URL
    local secure_url="http://${PUBLIC_IP}:${NGINX_PORT}/wg-dl/$expire_time/$secure_hash/$client_name.conf"

    # Expiry time in human readable format
    local expire_date=$(date -d "@$expire_time" "+%Y-%m-%d %H:%M:%S UTC")

    echo "$secure_url|$expire_date"
}

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
    echo "🔐 WireGuard Client Creator with Secure Downloads"
    echo "================================================="
    echo ""
    echo "Usage: $0 <client-name> [ip-suffix] [expiry-hours]"
    echo "Example: $0 laptop 5 4"
    echo ""
    exit 1
fi

CLIENT_NAME=$1
CLIENT_IP_SUFFIX=${2:-}
EXPIRY_HOURS=${3:-2}

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
log "Link expires in: $EXPIRY_HOURS hours"

echo ""
ask "Server endpoint (default: $ENDPOINT):"
read -p "> " custom_endpoint

if [[ -n "$custom_endpoint" ]]; then
    ENDPOINT="$custom_endpoint"
fi

echo ""
log "Client configuration:"
echo "Name: $CLIENT_NAME"
echo "IP: $CLIENT_IP"
echo "Endpoint: $ENDPOINT"
echo "Expiry: $EXPIRY_HOURS hours"
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

cat > $CLIENT_CONFIG_FILE << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF

# Create private-network-only config
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

# Copy to download directory
cp "$CLIENT_CONFIG_FILE" "$DOWNLOAD_DIR/$CLIENT_NAME.conf"
chown www-data:www-data "$DOWNLOAD_DIR/$CLIENT_NAME.conf"
chmod 644 "$DOWNLOAD_DIR/$CLIENT_NAME.conf"

# Generate secure download URL
SECURE_INFO=$(generate_secure_url "$CLIENT_NAME" "$EXPIRY_HOURS")
SECURE_URL=$(echo "$SECURE_INFO" | cut -d'|' -f1)
EXPIRE_DATE=$(echo "$SECURE_INFO" | cut -d'|' -f2)

# Reload WireGuard
log "Reloading configuration..."
wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE)

# Generate QR code for mobile
log "✅ Client created!"

echo ""
echo "🔗 Secure Download Link:"
echo "========================"
echo "$SECURE_URL"
echo ""
echo "⏰ Link expires: $EXPIRE_DATE"
echo "📱 This link is single-use and secure"
echo ""

echo "📋 Quick Download Commands:"
echo "=========================="
echo "# Download config file:"
echo "curl -O '$SECURE_URL'"
echo ""
echo "# Or with custom name:"
echo "curl '$SECURE_URL' -o my-vpn.conf"
echo ""

if command -v qrencode >/dev/null 2>&1; then
    echo "📱 QR Code (for mobile import):"
    echo "==============================="
    qrencode -t ansiutf8 < $CLIENT_CONFIG_FILE 2>/dev/null || echo "QR code generation failed"
    echo ""
fi

echo "📄 Configuration Preview:"
echo "========================="
cat $CLIENT_CONFIG_FILE

echo ""
echo "📊 Server Status:"
wg show

echo ""
log "🎉 Done! Send the secure download link to your client."
log "📂 Config files:"
echo "   Full VPN: $CLIENT_CONFIG_FILE"
echo "   Private Network Only: $WG_CLIENTS_DIR/$CLIENT_NAME-private-only.conf"
echo "   Download: $DOWNLOAD_DIR/$CLIENT_NAME.conf"
