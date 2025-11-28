#!/bin/bash
# wg-manage.sh - Quick WireGuard Management

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Check root
[[ $EUID -ne 0 ]] && error "Run as root"

# Auto-detect WireGuard configuration
WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/$WG_INTERFACE.conf"
WG_CLIENTS_DIR="/etc/wireguard/clients"

# Check if WireGuard is configured
if [[ ! -f $WG_CONFIG ]]; then
    error "WireGuard not configured. Run install.sh first."
fi

# Check if WireGuard is running
if ! systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
    warn "WireGuard service is not running"
    info "Start with: systemctl start wg-quick@$WG_INTERFACE"
fi

# Create clients directory if it doesn't exist
mkdir -p $WG_CLIENTS_DIR

# Functions
list_clients() {
    echo "🔌 WireGuard Clients:"
    echo "===================="

    if [[ ! -d $WG_CLIENTS_DIR ]] || [[ -z "$(ls -A $WG_CLIENTS_DIR 2>/dev/null)" ]]; then
        echo "No clients found"
        return
    fi

    # List from config file
    local count=0
    while IFS= read -r line; do
        if [[ $line =~ ^#\ Client:\ (.+)$ ]]; then
            client_name="${BASH_REMATCH[1]}"
            count=$((count + 1))

            # Get client IP
            client_ip=$(sed -n "/# Client: $client_name/,/^\[/p" $WG_CONFIG | grep "AllowedIPs" | cut -d'=' -f2 | tr -d ' ')

            # Check if client file exists
            client_file="$WG_CLIENTS_DIR/$client_name.conf"
            if [[ -f $client_file ]]; then
                status="✅"
            else
                status="❌"
            fi

            echo "$count. $client_name ($client_ip) $status"
        fi
    done < $WG_CONFIG

    if [[ $count -eq 0 ]]; then
        echo "No clients configured"
    fi
}

show_status() {
    echo "📊 WireGuard Server Status:"
    echo "==========================="
    echo ""

    # Service status
    if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
        echo "🟢 Service: Running"
    else
        echo "🔴 Service: Stopped"
    fi

    echo ""

    # Interface status
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
    echo "===================="
    echo ""

    # Show QR code if qrencode is available
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
    echo "📂 File location: $client_file"
}

remove_client() {
    local client_name="$1"
    local client_file="$WG_CLIENTS_DIR/$client_name.conf"

    # Check if client exists in config
    if ! grep -q "# Client: $client_name" $WG_CONFIG; then
        error "Client '$client_name' not found in server configuration"
    fi

    echo "🗑️  Removing client: $client_name"
    echo "================================"

    # Remove from server config
    log "Removing from server configuration..."

    # Create temp file and remove client section
    temp_file=$(mktemp)
    awk "
        /^# Client: $client_name\$/ { skip=1; next }
        skip && /^$/ { skip=0; next }
        skip && /^\[/ { skip=0 }
        !skip { print }
    " $WG_CONFIG > $temp_file

    # Replace original config
    mv $temp_file $WG_CONFIG

    # Remove client files
    if [[ -f $client_file ]]; then
        log "Removing client files..."
        rm -f $client_file
        rm -f "$WG_CLIENTS_DIR/$client_name-ipmi-only.conf"
    fi

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

backup_config() {
    local backup_dir="/etc/wireguard/backups"
    local backup_file="$backup_dir/backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    mkdir -p $backup_dir

    log "Creating backup: $backup_file"
    tar -czf $backup_file -C /etc/wireguard wg0.conf clients/ server_*.key *.txt 2>/dev/null || true

    log "✅ Backup created: $backup_file"
}

# Main menu
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
    "remove"|"rm"|"r")
        [[ -z $2 ]] && error "Usage: $0 remove <client-name>"
        echo "⚠️  This will permanently remove client '$2'"
        read -p "Continue? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && remove_client "$2" || echo "Cancelled"
        ;;
    "backup"|"b")
        backup_config
        ;;
    "restart")
        log "Restarting WireGuard service..."
        systemctl restart wg-quick@$WG_INTERFACE
        log "✅ Service restarted"
        show_status
        ;;
    "logs")
        echo "📜 WireGuard Logs:"
        echo "=================="
        journalctl -u wg-quick@$WG_INTERFACE -n 20 --no-pager
        ;;
    *)
        echo "🔧 WireGuard Management Tool"
        echo "============================"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "📋 Commands:"
        echo "  list, ls, l              List all clients"
        echo "  status, st, s            Show server status"
        echo "  show, sh <client>        Show client config + QR code"
        echo "  remove, rm, r <client>   Remove client"
        echo "  backup, b                Backup configuration"
        echo "  restart                  Restart WireGuard service"
        echo "  logs                     Show recent logs"
        echo ""
        echo "📁 Files:"
        echo "  Config: $WG_CONFIG"
        echo "  Clients: $WG_CLIENTS_DIR"
        echo ""
        ;;
esac
