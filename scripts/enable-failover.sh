#!/usr/bin/env bash
# Enable or sync multi-SNI failover from config/failover-endpoints.json
# Usage:
#   bash enable-failover.sh          — first-time enable or sync endpoints
#   bash enable-failover.sh --sync   — rebuild inbounds from endpoints file
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root"

for cmd in sing-box jq; do
    command -v "$cmd" &>/dev/null || err "Missing: $cmd"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/failover-common.sh
source "${SCRIPT_DIR}/lib/failover-common.sh"

CONFIG="/etc/sing-box/config.json"
CREDS="/root/vpn-backup/credentials.json"
ENDPOINTS_FILE="$(failover_endpoints_file)"

[[ -f "$CONFIG" ]] || err "Config not found: $CONFIG"
[[ -f "$CREDS"  ]] || err "Credentials not found: $CREDS"
[[ -f "$ENDPOINTS_FILE" ]] || err "Endpoints file not found: $ENDPOINTS_FILE"

SYNC=false
[[ "${1:-}" == "--sync" ]] && SYNC=true

if failover_config_has_multi_inbound "$CONFIG" && ! $SYNC; then
    info "Failover already enabled — syncing endpoints from ${ENDPOINTS_FILE}..."
    SYNC=true
fi

if $SYNC || failover_config_has_multi_inbound "$CONFIG"; then
    TS=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG" "/root/vpn-backup/config.json.bak.${TS}"
    log "Backup: /root/vpn-backup/config.json.bak.${TS}"

    info "Endpoints:"
    jq -r '.endpoints[] | "  \(.port) \(.server_name) (\(.tier // "extra"))"' "$ENDPOINTS_FILE"

    failover_apply_to_server "$CONFIG" "$CREDS" "$ENDPOINTS_FILE" "$SCRIPT_DIR" \
        || err "Failed to apply failover config"

    log "UFW ports: $(failover_endpoint_ports "$ENDPOINTS_FILE")"
    log "Failover synced ($(jq '.endpoints | length' "$ENDPOINTS_FILE") SNI)"
else
    TS=$(date +%Y%m%d_%H%M%S)
    cp "$CONFIG" "/root/vpn-backup/config.json.bak.${TS}"
    log "Backup: /root/vpn-backup/config.json.bak.${TS}"
    failover_apply_to_server "$CONFIG" "$CREDS" "$ENDPOINTS_FILE" "$SCRIPT_DIR" \
        || err "Failed to enable failover"
    log "Failover enabled"
fi

PRIMARY_SN=$(jq -r '.endpoints[0].server_name' "$ENDPOINTS_FILE")
PRIMARY_PORT=$(jq -r '.endpoints[0].port' "$ENDPOINTS_FILE")

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Next steps for users"
echo "══════════════════════════════════════════════════════════════════"
echo "  1. Re-distribute /root/vpn-backup/clients/<user>-singbox.json"
echo "  2. Import into sing-box / Hiddify (urltest picks best SNI)"
echo "  3. Primary vless:// link unchanged: ${PRIMARY_SN}:${PRIMARY_PORT}"
echo "══════════════════════════════════════════════════════════════════"
