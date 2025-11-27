#!/bin/bash
# wg-manage.sh - Quick WireGuard Management

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root"
[[ ! -f /etc/wireguard/server.env ]] && error "Server not configured"
source /etc/wireguard/server.env

case "${1:-}" in
    "list"|"ls")
        echo "🔌 Active Clients:"
        wg show $WG_INTERFACE peers | while read peer; do
            client=$(grep -B2 "$peer" /etc/wireguard/$WG_INTERFACE.conf | grep "# Client:" | cut -d':' -f2 | tr -d ' ')
            echo "• $client"
        done
        ;;
    "status"|"st")
        echo "📊 Server Status:"
        wg show
        ;;
    "remove"|"rm")
        [[ -z $2 ]] && error "Usage: $0 remove <client-name>"
        CLIENT_NAME=$2
        CLIENT_FILE="/etc/wireguard/clients/$CLIENT_NAME.conf"

        [[ ! -f $CLIENT_FILE ]] && error "Client '$CLIENT_NAME' not found"

        echo "🗑️  Removing client: $CLIENT_NAME"
        sed -i "/# Client: $CLIENT_NAME/,/^$/d" /etc/wireguard/$WG_INTERFACE.conf
        rm -f $CLIENT_FILE
        wg syncconf $WG_INTERFACE <(wg-quick strip $WG_INTERFACE)
        log "Client removed"
        ;;
    "show")
        [[ -z $2 ]] && error "Usage: $0 show <client-name>"
        CLIENT_FILE="/etc/wireguard/clients/$2.conf"
        [[ ! -f $CLIENT_FILE ]] && error "Client '$2' not found"

        echo "📱 $2 Configuration:"
        qrencode -t ansiutf8 < $CLIENT_FILE
        echo ""
        cat $CLIENT_FILE
        ;;
    *)
        echo "🔧 WireGuard Management"
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  list, ls          List all clients"
        echo "  status, st        Show server status"
        echo "  show <client>     Show client config + QR"
        echo "  remove <client>   Remove client"
        ;;
esac
