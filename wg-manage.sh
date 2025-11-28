#!/bin/bash
# wg-manage.sh - WireGuard + Nginx Management Tool

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
highlight() { echo -e "${CYAN}[LINK]${NC} $1"; }

# Check root
[[ $EUID -ne 0 ]] && error "Run as root"

# Configuration
WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/$WG_INTERFACE.conf"
WG_CLIENTS_DIR="/etc/wireguard/clients"
DOWNLOAD_DIR="/var/www/wireguard-dl"
NGINX_PORT="8080"
SERVER_PUBLIC_IP_FILE="/etc/wireguard/server_public_ip.txt"
SERVER_DOMAIN_FILE="/etc/wireguard/server_domain.txt"

# Check if WireGuard is configured
if [[ ! -f $WG_CONFIG ]]; then
    error "WireGuard not configured. Run install.sh first."
fi

# Load server info
if [[ -f $SERVER_PUBLIC_IP_FILE ]]; then
    PUBLIC_IP=$(cat $SERVER_PUBLIC_IP_FILE)
else
    PUBLIC_IP="localhost"
fi

if [[ -f $SERVER_DOMAIN_FILE ]]; then
    SERVER_DOMAIN=$(cat $SERVER_DOMAIN_FILE)
else
    SERVER_DOMAIN="$PUBLIC_IP"
fi

# Functions
generate_download_link() {
    local client_name="$1"
    local download_url="http://${SERVER_DOMAIN}:${NGINX_PORT}/$client_name.conf"
    echo "$download_url"
}

list_clients() {
    echo "🔌 WireGuard Clients:"
    echo "===================="

    if [[ ! -d $WG_CLIENTS_DIR ]] || [[ -z "$(ls -A $WG_CLIENTS_DIR 2>/dev/null)" ]]; then
        echo "No clients found"
        return
    fi

    local count=0
    while IFS= read -r line; do
        if [[ $line =~ ^#\ Client:\ (.+)$ ]]; then
            client_name="${BASH_REMATCH[1]}"
            count=$((count + 1))

            # Get client IP
            client_ip=$(sed -n "/# Client: $client_name/,/^\[/p" $WG_CONFIG | grep "AllowedIPs" | cut -d'=' -f2 | tr -d ' ')

            # Check if client file exists
            client_file="$WG_CLIENTS_DIR/$client_name.conf"
            download_file="$DOWNLOAD_DIR/$client_name.conf"

            # Status indicators
            local config_status="❌"
            local download_status="❌"
            local connection_status="⚫"

            [[ -f $client_file ]] && config_status="✅"
            [[ -f $download_file ]] && download_status="📥"

            # Check if client is connected
            if [[ -f $client_file ]]; then
                local client_pubkey=$(grep "PublicKey" "$client_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
                if [[ -n "$client_pubkey" ]] && wg show $WG_INTERFACE peers 2>/dev/null | grep -q "$client_pubkey"; then
                    if wg show $WG_INTERFACE | grep -A3 "$client_pubkey" | grep -q "latest handshake"; then
                        connection_status="🟢"
                    else
                        connection_status="🟡"
                    fi
                fi
            fi

            echo "$count. $client_name ($client_ip) $config_status $download_status $connection_status"
        fi
    done < $WG_CONFIG

    if [[ $count -eq 0 ]]; then
        echo "No clients configured"
    else
        echo ""
        echo "Legend: ✅Config 📥Download 🟢Connected 🟡Configured ⚫Offline ❌Missing"
    fi
}

show_status() {
    echo "📊 Server Status:"
    echo "================="
    echo ""

    # WireGuard status
    if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
        echo "🟢 WireGuard: Running"
    else
        echo "🔴 WireGuard: Stopped"
    fi

    # Nginx status
    if systemctl is-active --quiet nginx; then
        echo "🟢 Nginx: Running"

        # Test download server
        if curl -s "http://localhost:$NGINX_PORT/health" | grep -q "OK"; then
            echo "🟢 Download Server: Operational (port $NGINX_PORT)"
        else
            echo "🟡 Download Server: Service running but not responding"
        fi
    else
        echo "🔴 Nginx: Stopped"
    fi

    echo ""
    echo "🌐 Server URLs:"
    echo "Health: http://$SERVER_DOMAIN:$NGINX_PORT/health"
    echo "Info: http://$SERVER_DOMAIN:$NGINX_PORT/"
    echo ""

    # WireGuard interface details
    if wg show $WG_INTERFACE >/dev/null 2>&1; then
        wg show $WG_INTERFACE
    else
        echo "Interface $WG_INTERFACE not found"
    fi
}

show_client() {
    local client_name="$1"
    local client_file="$WG_CLIENTS_DIR/$client_name.conf"

    if [[ ! -f $client_file ]]; then
        error "Client '$client_name' not found"
    fi

    echo "📱 Client: $client_name"
    echo "==================="
    echo ""

    # Show download link if available
    local download_file="$DOWNLOAD_DIR/$client_name.conf"
    if [[ -f $download_file ]]; then
        echo "📥 Download file exists - can generate secure link"
        echo ""
    fi

    # Show QR code if available
    if command -v qrencode >/dev/null 2>&1; then
        echo "📱 QR Code:"
        echo "-----------"
        qrencode -t ansiutf8 < $client_file 2>/dev/null || echo "QR code generation failed"
        echo ""
    fi

    echo "📄 Configuration:"
    echo "-----------------"
    cat $client_file

    echo ""
    echo "📂 Files:"
    echo "Config: $client_file"
    [[ -f $download_file ]] && echo "Download: $download_file"
    [[ -f "$WG_CLIENTS_DIR/$client_name-private-only.conf" ]] && echo "Private Network Only: $WG_CLIENTS_DIR/$client_name-private-only.conf"
}

create_download_link() {
    local client_name="$1"
    local client_file="$WG_CLIENTS_DIR/$client_name.conf"
    local download_file="$DOWNLOAD_DIR/$client_name.conf"

    if [[ ! -f $client_file ]]; then
        error "Client '$client_name' not found"
    fi

    # Copy to download directory if not exists
    if [[ ! -f $download_file ]]; then
        log "Copying config to download directory..."
        cp "$client_file" "$download_file"
        chown www-data:www-data "$download_file"
        chmod 644 "$download_file"
    fi

    # Generate download link
    local download_url=$(generate_download_link "$client_name")

    echo "🔗 Download Link for: $client_name"
    echo "=================================="
    highlight "$download_url"
    echo ""
    echo "📱 Temporary link for configuration download"
    echo "⚠️  Files are automatically cleaned up after 24 hours"
    echo ""
    echo "📋 Download commands:"
    echo "curl -O '$download_url'"
    echo "wget '$download_url'"
}

remove_client() {
    local client_name="$1"
    local client_file="$WG_CLIENTS_DIR/$client_name.conf"
    local download_file="$DOWNLOAD_DIR/$client_name.conf"

    if ! grep -q "# Client: $client_name" $WG_CONFIG; then
        error "Client '$client_name' not found in server configuration"
    fi

    echo "🗑️  Removing client: $client_name"
    echo "================================"

    # Remove from server config
    log "Removing from server configuration..."
    temp_file=$(mktemp)
    awk "
        /^# Client: $client_name\$/ { skip=1; next }
        skip && /^$/ { skip=0; next }
        skip && /^\[/ { skip=0 }
        !skip { print }
    " $WG_CONFIG > $temp_file
    mv $temp_file $WG_CONFIG

    # Remove all client files
    log "Removing client files..."
    rm -f "$client_file"
    rm -f "$WG_CLIENTS_DIR/$client_name-private-only.conf"
    rm -f "$download_file"

    # Reload WireGuard
    log "Reloading WireGuard..."
    if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
        wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE) 2>/dev/null || {
            warn "Failed to reload config, restarting service..."
            systemctl restart wg-quick@$WG_INTERFACE
        }
    fi

    log "✅ Client '$client_name' removed successfully"
}

cleanup_downloads() {
    if [[ ! -d $DOWNLOAD_DIR ]]; then
        warn "Download directory not found: $DOWNLOAD_DIR"
        return
    fi

    log "Cleaning up download files..."

    local count=0
    for file in "$DOWNLOAD_DIR"/*.conf; do
        [[ -f "$file" ]] || continue

        local age_hours=$(( ($(date +%s) - $(stat -c %Y "$file")) / 3600 ))
        if [[ $age_hours -gt 24 ]]; then
            rm -f "$file"
            count=$((count + 1))
            log "Removed: $(basename "$file") (${age_hours}h old)"
        fi
    done

    if [[ $count -eq 0 ]]; then
        log "No old files to clean up"
    else
        log "✅ Cleaned up $count old files"
    fi
}

show_download_stats() {
    echo "📊 Download Statistics:"
    echo "======================"

    if [[ ! -d $DOWNLOAD_DIR ]]; then
        echo "Download directory not configured"
        return
    fi

    local total_files=$(find "$DOWNLOAD_DIR" -name "*.conf" 2>/dev/null | wc -l)
    echo "📥 Available downloads: $total_files"

    if [[ $total_files -gt 0 ]]; then
        echo ""
        echo "📂 Download files:"
        for file in "$DOWNLOAD_DIR"/*.conf; do
            [[ -f "$file" ]] || continue

            local basename=$(basename "$file" .conf)
            local size=$(du -h "$file" | cut -f1)
            local age_hours=$(( ($(date +%s) - $(stat -c %Y "$file")) / 3600 ))

            echo "  $basename ($size, ${age_hours}h old)"
        done
    fi

    # Nginx access stats (if logs exist)
    if [[ -f "/var/log/nginx/access.log" ]]; then
        echo ""
        echo "🌐 Recent downloads (last 24h):"
        grep "wg-dl" /var/log/nginx/access.log 2>/dev/null | \
        grep "$(date -d '24 hours ago' '+%d/%b/%Y')" | \
        tail -5 | \
        awk '{print "  " $1 " - " $7 " [" $4 " " $5 "]"}' || echo "  No recent download logs"
    fi
}

backup_config() {
    local backup_dir="/etc/wireguard/backups"
    local backup_file="$backup_dir/backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    mkdir -p $backup_dir

    log "Creating backup: $backup_file"
    tar -czf $backup_file -C /etc/wireguard \
        wg0.conf clients/ server_*.key *.txt \
        2>/dev/null || true

    # Include nginx config if exists
    if [[ -f "/etc/nginx/sites-available/wireguard-dl" ]]; then
        tar -rf $backup_file -C / etc/nginx/sites-available/wireguard-dl 2>/dev/null || true
    fi

    log "✅ Backup created: $backup_file"
    echo "📦 Backup size: $(du -h $backup_file | cut -f1)"
}

# Main command handling
case "${1:-}" in
    "list"|"ls"|"l")
        list_clients
        ;;
    "status"|"st"|"s")
        show_status
        ;;
    "show"|"sh")
        [[ -z $2 ]] && error "Usage: $0 show <client-name>"
        show_client "$2"
        ;;
    "link"|"dl")
        [[ -z $2 ]] && error "Usage: $0 link <client-name>"
        create_download_link "$2"
        ;;
    "remove"|"rm"|"r")
        [[ -z $2 ]] && error "Usage: $0 remove <client-name>"
        echo "⚠️  This will permanently remove client '$2'"
        read -p "Continue? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && remove_client "$2" || echo "Cancelled"
        ;;
    "cleanup"|"clean")
        cleanup_downloads
        ;;
    "stats"|"downloads")
        show_download_stats
        ;;
    "backup"|"b")
        backup_config
        ;;
    "restart")
        log "Restarting services..."
        systemctl restart wg-quick@$WG_INTERFACE
        systemctl restart nginx
        log "✅ Services restarted"
        show_status
        ;;
    "logs")
        echo "📜 WireGuard Logs:"
        echo "=================="
        journalctl -u wg-quick@$WG_INTERFACE -n 15 --no-pager
        echo ""
        echo "📜 Nginx Logs:"
        echo "=============="
        journalctl -u nginx -n 10 --no-pager
        ;;
    "nginx-logs")
        echo "🌐 Nginx Access Logs (last 20):"
        echo "==============================="
        tail -20 /var/log/nginx/access.log 2>/dev/null || echo "No access logs found"
        ;;
    *)
        echo "🔧 WireGuard + Nginx Management Tool"
        echo "====================================="
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "📋 Client Management:"
        echo "  list, ls, l              List all clients with status"
        echo "  show, sh <client>        Show client config + QR code"
        echo "  remove, rm, r <client>   Remove client completely"
        echo "  link, dl <client>        Generate download link"
        echo ""
        echo "📊 Server Management:"
        echo "  status, st, s            Show server status"
        echo "  stats, downloads         Show download statistics"
        echo "  cleanup, clean           Remove old download files"
        echo "  backup, b                Backup all configurations"
        echo "  restart                  Restart all services"
        echo ""
        echo "📜 Monitoring:"
        echo "  logs                     Show recent service logs"
        echo "  nginx-logs               Show nginx access logs"
        echo ""
        echo "📁 Files:"
        echo "  WireGuard: $WG_CONFIG"
        echo "  Clients: $WG_CLIENTS_DIR"
        echo "  Downloads: $DOWNLOAD_DIR"
        echo ""
        echo "🔗 Server: http://$SERVER_DOMAIN:$NGINX_PORT/"
        ;;
esac
