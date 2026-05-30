#!/usr/bin/env bash
# Generate sing-box client config with urltest failover across multiple SNI endpoints.
# Usage:
#   bash generate-client-config.sh              — all users
#   bash generate-client-config.sh <username>   — one user
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/failover-common.sh
source "${SCRIPT_DIR}/lib/failover-common.sh"

CREDS="/root/vpn-backup/credentials.json"
CLIENTS_DIR="/root/vpn-backup/clients"

[[ -f "$CREDS" ]] || err "Credentials not found: $CREDS"
jq -e '.failover.enabled == true' "$CREDS" &>/dev/null \
    || err "Failover not enabled. Run: bash scripts/enable-failover.sh"

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

if [[ -n "${1:-}" ]]; then
    USERNAME="$1"
    jq -e --arg u "$USERNAME" '.users[] | select(.name == $u)' "$CREDS" &>/dev/null \
        || err "User not found: $USERNAME"
    OUT="${CLIENTS_DIR}/${USERNAME}-singbox.json"
    failover_generate_client_config "$CREDS" "$USERNAME" "$OUT"
    chmod 600 "$OUT"
    log "Client config: $OUT"
    echo ""
    echo "  Import into sing-box / Hiddify, or use proxy: socks5://127.0.0.1:2080"
    exit 0
fi

info "Generating client configs for all users..."
failover_generate_all_client_configs "$CREDS" "$CLIENTS_DIR"
log "Client configs saved to ${CLIENTS_DIR}/"
