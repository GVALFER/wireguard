#!/bin/bash
# change-domain.sh - Change WireGuard Server Domain/IP for Nginx

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

# Configuration files
WG_CONFIG="/etc/wireguard/wg0.conf"
SERVER_DOMAIN_FILE="/etc/wireguard/server_domain.txt"
SERVER_PUBLIC_IP_FILE="/etc/wireguard/server_public_ip.txt"
NGINX_CONFIG="/etc/nginx/sites-available/wireguard-dl"
NGINX_PORT="8080"

echo "🌐 WireGuard Domain Configuration Updater"
echo "=========================================="
echo ""

# Check if WireGuard is installed
[[ ! -f $WG_CONFIG ]] && error "WireGuard not found. Run install-wireguard.sh first."
[[ ! -f $SERVER_PUBLIC_IP_FILE ]] && error "Server IP file not found. Installation may be incomplete."

# Load current configuration
PUBLIC_IP=$(cat $SERVER_PUBLIC_IP_FILE)
CURRENT_DOMAIN=""

if [[ -f $SERVER_DOMAIN_FILE ]]; then
    CURRENT_DOMAIN=$(cat $SERVER_DOMAIN_FILE)
    log "Current domain/IP: $CURRENT_DOMAIN"
else
    warn "Domain file not found. Creating with current IP: $PUBLIC_IP"
    CURRENT_DOMAIN="$PUBLIC_IP"
    echo "$CURRENT_DOMAIN" > $SERVER_DOMAIN_FILE
fi

echo ""
ask "Do you want to:"
echo "1) Use IP address ($PUBLIC_IP)"
echo "2) Use custom domain"
echo "3) Cancel"
echo ""
read -p "Select option (1-3): " CHOICE

case $CHOICE in
    1)
        NEW_DOMAIN="$PUBLIC_IP"
        log "Selected: IP address mode"
        ;;
    2)
        ask "Enter your domain (e.g., vpn.yourdomain.com):"
        read -p "> " CUSTOM_DOMAIN
        if [[ -z "$CUSTOM_DOMAIN" ]]; then
            error "No domain provided"
        fi
        NEW_DOMAIN="$CUSTOM_DOMAIN"
        log "Selected: Custom domain ($NEW_DOMAIN)"
        ;;
    3)
        log "Operation cancelled"
        exit 0
        ;;
    *)
        error "Invalid option"
        ;;
esac

echo ""
if [[ "$NEW_DOMAIN" == "$CURRENT_DOMAIN" ]]; then
    log "Domain unchanged. No action needed."
    exit 0
fi

log "Changing domain from '$CURRENT_DOMAIN' to '$NEW_DOMAIN'"
echo ""

ask "Continue with domain change? (Y/n):"
read -p "> " CONTINUE
CONTINUE=${CONTINUE:-y}
[[ ! $CONTINUE =~ ^[Yy]$ ]] && { log "Domain change cancelled"; exit 0; }

# Update domain file
log "Updating domain configuration..."
echo "$NEW_DOMAIN" > $SERVER_DOMAIN_FILE
chmod 644 $SERVER_DOMAIN_FILE

# Update nginx configuration
if [[ -f $NGINX_CONFIG ]]; then
    log "Updating nginx configuration..."
    sed -i "s/server_name .*/server_name $NEW_DOMAIN;/" $NGINX_CONFIG

    # Test nginx configuration
    if nginx -t >/dev/null 2>&1; then
        log "Nginx configuration test passed"
    else
        error "Nginx configuration test failed. Check $NGINX_CONFIG manually"
    fi

    # Restart nginx
    log "Restarting nginx..."
    systemctl restart nginx

    if systemctl is-active --quiet nginx; then
        log "✅ Nginx restarted successfully"
    else
        error "❌ Failed to restart nginx"
    fi
else
    warn "Nginx configuration file not found: $NGINX_CONFIG"
fi

# Verify services
log "Verifying services..."
sleep 2

WG_STATUS="❌"
NGINX_STATUS="❌"

if systemctl is-active --quiet wg-quick@wg0; then
    WG_STATUS="✅"
fi

if systemctl is-active --quiet nginx && curl -s "http://localhost:$NGINX_PORT/health" | grep -q "OK"; then
    NGINX_STATUS="✅"
fi

echo ""
log "🎉 Domain change completed!"
echo ""
echo "📋 Updated Configuration:"
echo "========================="
echo "Previous: $CURRENT_DOMAIN"
echo "Current:  $NEW_DOMAIN"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "📊 Service Status:"
echo "WireGuard: $WG_STATUS"
echo "Nginx: $NGINX_STATUS"
echo ""
echo "🌐 Updated URLs:"
echo "Health Check: http://$NEW_DOMAIN:$NGINX_PORT/health"
echo "Info Page: http://$NEW_DOMAIN:$NGINX_PORT/"
echo ""

if [[ "$WG_STATUS" = "✅" && "$NGINX_STATUS" = "✅" ]]; then
    log "✅ All services running successfully with new domain!"
    echo ""
    echo "🔧 Next Steps:"
    echo "=============="
    echo "1. New client download links will use: $NEW_DOMAIN"
    echo "2. Existing clients are not affected (they use WireGuard endpoints)"
    echo "3. Test the new URLs above to verify functionality"

    if [[ "$NEW_DOMAIN" != "$PUBLIC_IP" ]]; then
        echo "4. Ensure your domain '$NEW_DOMAIN' points to IP: $PUBLIC_IP"
        echo "5. Consider setting up SSL/TLS for https://$NEW_DOMAIN"
    fi
else
    warn "⚠️ Some services may need attention. Check logs:"
    echo "sudo journalctl -u wg-quick@wg0 -f"
    echo "sudo journalctl -u nginx -f"
fi
