#!/bin/bash
# install-wireguard.sh - WireGuard Server Installation Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration variables
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
IPMI_NET="10.10.1.0/24"

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

log "🚀 WireGuard Installation"
echo "========================="

# Detect public IP
log "Detecting public IP..."
PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)

if [[ -z "$PUBLIC_IP" ]]; then
    error "Failed to detect public IP. Check internet connection."
fi

log "Detected public IP: $PUBLIC_IP"

# Detect network interface
log "Detecting network interfaces..."
INTERFACES=($(ip route | grep default | awk '{print $5}' | sort -u))

if [[ ${#INTERFACES[@]} -eq 0 ]]; then
    error "No network interface found"
elif [[ ${#INTERFACES[@]} -eq 1 ]]; then
    PUBLIC_INTERFACE=${INTERFACES[0]}
    log "Auto-detected interface: $PUBLIC_INTERFACE"
else
    log "Multiple interfaces found:"
    for i in "${!INTERFACES[@]}"; do
        INTERFACE=${INTERFACES[$i]}
        IP=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | head -1)
        log "$((i+1))) $INTERFACE ($IP)"
    done

    while true; do
        info "Select interface [1-${#INTERFACES[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#INTERFACES[@]} ]]; then
            PUBLIC_INTERFACE=${INTERFACES[$((choice-1))]}
            break
        else
            warn "Invalid choice. Please select 1-${#INTERFACES[@]}"
        fi
    done
fi

log "Using interface: $PUBLIC_INTERFACE"

# Configuration summary
echo ""
log "Configuration:"
echo "Interface: $WG_INTERFACE"
echo "Port: $WG_PORT"
echo "Public IP: $PUBLIC_IP"
echo "Network Interface: $PUBLIC_INTERFACE"
echo "VPN Network: $WG_NET"
echo "IPMI Network: $IPMI_NET"
echo ""

info "Continue with installation? (Y/n): "
read -r confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    log "Installation cancelled."
    exit 0
fi

# Update system
log "Updating system packages..."
apt update -y

# Install WireGuard
log "Installing WireGuard..."
apt install -y wireguard wireguard-tools qrencode curl

# Enable IP forwarding
log "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Create WireGuard directory
mkdir -p /etc/wireguard
cd /etc/wireguard

# Generate server keys
log "Generating server keys..."
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)

# Save public IP for client scripts
echo "$PUBLIC_IP" > server_public_ip.txt

log "Server Public Key: $SERVER_PUBLIC_KEY"

# Create server configuration
log "Creating server configuration..."
cat > /etc/wireguard/$WG_INTERFACE.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
PostUp = iptables -t nat -A POSTROUTING -s $WG_NET -d $IPMI_NET -o $PUBLIC_INTERFACE -j MASQUERADE; iptables -t nat -A POSTROUTING -s $WG_NET -o $PUBLIC_INTERFACE -j MASQUERADE; iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $WG_NET -d $IPMI_NET -o $PUBLIC_INTERFACE -j MASQUERADE; iptables -t nat -D POSTROUTING -s $WG_NET -o $PUBLIC_INTERFACE -j MASQUERADE; iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT

# Clients will be added here

EOF

# Set permissions
chmod 600 /etc/wireguard/$WG_INTERFACE.conf

# Enable and start WireGuard
log "Enabling and starting WireGuard service..."
systemctl enable wg-quick@$WG_INTERFACE
systemctl start wg-quick@$WG_INTERFACE

# Configure firewall if ufw is available
if command -v ufw &> /dev/null; then
    log "Configuring UFW firewall..."
    ufw allow $WG_PORT/udp
    echo "y" | ufw enable 2>/dev/null || true
fi

# Create clients directory
mkdir -p /etc/wireguard/clients

# Display information
log "✅ WireGuard installation completed!"
echo ""
echo "📋 Configuration Summary:"
echo "========================="
echo "Server Public Key: $SERVER_PUBLIC_KEY"
echo "Server Public IP: $PUBLIC_IP"
echo "Server VPN IP: $WG_SERVER_IP"
echo "Listen Port: $WG_PORT"
echo "VPN Network: $WG_NET"
echo "IPMI Network: $IPMI_NET"
echo "Config file: /etc/wireguard/$WG_INTERFACE.conf"
echo ""
echo "🔧 Next steps:"
echo "1. Run 'wg show' to verify installation"
echo "2. Use './create-client.sh <name>' to add clients"
echo "3. Configure your router/firewall to forward port $WG_PORT"

# Verify installation
log "Verifying installation..."
sleep 2
if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
    log "✅ WireGuard service is running"
    wg show
else
    error "❌ WireGuard service failed to start"
fi

echo ""
log "🎉 Installation completed successfully!"
echo "Public IP saved to: /etc/wireguard/server_public_ip.txt"
