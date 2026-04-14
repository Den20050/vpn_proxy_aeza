#!/usr/bin/env bash
# Display vless:// links and QR codes for all users from the current config.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

CREDS="/root/vpn-backup/credentials.json"
[[ -f "$CREDS" ]] || err "Credentials not found: $CREDS  (run generate-keys.sh first)"

SERVER_IP=$(jq -r '.server_ip'          "$CREDS")
SERVER_NAME=$(jq -r '.server_name'      "$CREDS")
PUBLIC_KEY=$(jq -r '.public_key'        "$CREDS")
SHORT_ID=$(jq -r '.short_ids.primary'   "$CREDS")
PORT=$(jq -r '.users[0].link | split("@")[1] | split(":")[1] | split("?")[0]' "$CREDS" 2>/dev/null || echo "443")

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  VLESS + Reality — Connection Links"
echo "  Server: ${SERVER_IP}:${PORT}  SNI: ${SERVER_NAME}"
echo "══════════════════════════════════════════════════════════════════"

jq -r '.users[] | "\(.name)|\(.uuid)|\(.link)"' "$CREDS" | while IFS='|' read -r NAME UUID LINK; do
    echo ""
    echo "── ${NAME} ──────────────────────────────────────────────────"
    echo "$LINK"
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
