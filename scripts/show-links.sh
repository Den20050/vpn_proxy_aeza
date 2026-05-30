#!/usr/bin/env bash
# Display vless:// links and QR codes for all users from the current config.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/failover-common.sh
source "${SCRIPT_DIR}/lib/failover-common.sh"

CREDS="/root/vpn-backup/credentials.json"
[[ -f "$CREDS" ]] || err "Credentials not found: $CREDS  (run generate-keys.sh first)"

SERVER_IP=$(jq -r '.server_ip'          "$CREDS")
SERVER_NAME=$(jq -r '.server_name'      "$CREDS")
PUBLIC_KEY=$(jq -r '.public_key'        "$CREDS")
SHORT_ID=$(jq -r '.short_ids.primary'   "$CREDS")

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  VLESS + Reality — Connection Links"
echo "  Server: ${SERVER_IP}  Primary SNI: ${SERVER_NAME}"
if jq -e '.failover.enabled == true' "$CREDS" &>/dev/null; then
    echo "  Failover SNIs: $(jq -r '[.failover.endpoints[].server_name]|join(", ")' "$CREDS")"
    echo "  Auto-switch configs: /root/vpn-backup/clients/<user>-singbox.json"
fi
echo "══════════════════════════════════════════════════════════════════"

jq -r '.users[] | "\(.name)|\(.link)"' "$CREDS" | while IFS='|' read -r NAME LINK; do
    echo ""
    echo "── ${NAME} (primary) ─────────────────────────────────────────"
    echo "$LINK"
    if jq -e '.failover.enabled == true' "$CREDS" &>/dev/null; then
        jq -r --arg u "$NAME" '.users[] | select(.name==$u) | .failover_links[]?' "$CREDS" | while read -r flink; do
            echo "  alt: $flink"
        done
        [[ -f "/root/vpn-backup/clients/${NAME}-singbox.json" ]] && \
            echo "  client: /root/vpn-backup/clients/${NAME}-singbox.json"
    fi
    echo ""
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$LINK"
    fi
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Public key : $PUBLIC_KEY"
echo "  Short ID   : $SHORT_ID"
echo "══════════════════════════════════════════════════════════════════"
