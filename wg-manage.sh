#!/bin/bash
# wg-manage.sh - WireGuard Management Tool

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
highlight() { echo -e "${CYAN}[HIGHLIGHT]${NC} $1"; }

# Check root
[[ $EUID -ne 0 ]] && error "Run as root"

# Configuration
WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/$WG_INTERFACE.conf"
WG_CLIENTS_DIR="/etc/wireguard/clients"
SERVER_PUBLIC_IP_FILE="/etc/wireguard/server_public_ip.txt"

# Check if WireGuard is configured
if [[ ! -f $WG_CONFIG ]]; then
    error "WireGuard not configured. Run install-wireguard.sh first."
fi

# Load server info
if [[ -f $SERVER_PUBLIC_IP_FILE ]]; then
    PUBLIC_IP=$(cat $SERVER_PUBLIC_IP_FILE)
else
    PUBLIC_IP="localhost"
fi

# Functions
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

            # Status indicators
            local config_status="❌"
            local connection_status="⚫"

            [[ -f $client_file ]] && config_status="✅"

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

            echo "$count. $client_name ($client_ip) $config_status $connection_status"
        fi
    done < $WG_CONFIG

    if [[ $count -eq 0 ]]; then
        echo "No clients configured"
    else
        echo ""
        echo "Legend: ✅Config 🟢Connected 🟡Configured ⚫Offline ❌Missing"
    fi
}

show_status() {
    echo "📊 Server Status:"
    echo "================="
    echo ""

    # WireGuard status
    if systemctl is-active --quiet wg-quick@$WG_INTERFACE; then
        echo "🟢 WireGuard: Running"
        echo "📡 Server IP: $PUBLIC_IP"
        echo "🔌 Interface: $WG_INTERFACE"
    else
        echo "🔴 WireGuard: Stopped"
    fi

    echo ""

    # WireGuard interface details
    if wg show $WG_INTERFACE >/dev/null 2>&1; then
        echo "📋 Interface Details:"
        wg show $WG_INTERFACE
    else
        echo "❌ Interface $WG_INTERFACE not found"
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
    echo "Main config: $client_file"
    [[ -f "$WG_CLIENTS_DIR/$client_name-private-only.conf" ]] && echo "Private network only: $WG_CLIENTS_DIR/$client_name-private-only.conf"
}

remove_client() {
    local client_name="$1"
    local client_file="$WG_CLIENTS_DIR/$client_name.conf"

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
    tar -czf $backup_file -C /etc/wireguard \
        wg0.conf clients/ server_*.key *.txt \
        2>/dev/null || true

    log "✅ Backup created: $backup_file"
    echo "📦 Backup size: $(du -h $backup_file | cut -f1)"
}

show_config() {
    echo "📄 Server Configuration:"
    echo "======================="
    echo ""
    cat $WG_CONFIG
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
    "remove"|"rm"|"r")
        [[ -z $2 ]] && error "Usage: $0 remove <client-name>"
        echo "⚠️  This will permanently remove client '$2'"
        read -p "Continue? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && remove_client "$2" || echo "Cancelled"
        ;;
    "backup"|"b")
        backup_config
        ;;
    "config"|"conf")
        show_config
        ;;
    "restart")
        log "Restarting WireGuard service..."
        systemctl restart wg-quick@$WG_INTERFACE
        log "✅ WireGuard service restarted"
        show_status
        ;;
    "logs")
        echo "📜 WireGuard Logs:"
        echo "=================="
        journalctl -u wg-quick@$WG_INTERFACE -n 20 --no-pager
        ;;
    "peers")
        echo "👥 Active Peers:"
        echo "==============="
        if wg show $WG_INTERFACE >/dev/null 2>&1; then
            wg show $WG_INTERFACE peers
        else
            echo "No peers found or WireGuard not running"
        fi
        ;;
    *)
        echo "🔧 WireGuard Management Tool"
        echo "============================"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "📋 Client Management:"
        echo "  list, ls, l              List all clients with status"
        echo "  show, sh <client>        Show client config + QR code"
        echo "  remove, rm, r <client>   Remove client completely"
        echo ""
        echo "📊 Server Management:"
        echo "  status, st, s            Show server status"
        echo "  config, conf             Show server configuration"
        echo "  backup, b                Backup all configurations"
        echo "  restart                  Restart WireGuard service"
        echo "  peers                    Show active peers"
        echo ""
        echo "📜 Monitoring:"
        echo "  logs                     Show recent WireGuard logs"
        echo ""
        echo "📁 Files:"
        echo "  Server config: $WG_CONFIG"
        echo "  Client configs: $WG_CLIENTS_DIR"
        echo ""
        echo "🌐 Server: $PUBLIC_IP"
        ;;
esac
