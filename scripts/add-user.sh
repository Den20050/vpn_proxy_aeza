#!/usr/bin/env bash
# Add a new user to the existing Sing-box config and show their vless:// link.
# Usage: bash add-user.sh <username>
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root"
[[ -z "${1:-}" ]]  && err "Usage: $0 <username>"

for cmd in sing-box jq qrencode; do
    command -v "$cmd" &>/dev/null || err "Missing: $cmd"
done

USERNAME="$1"
CONFIG="/etc/sing-box/config.json"
CREDS="/root/vpn-backup/credentials.json"

[[ -f "$CONFIG" ]] || err "Config not found: $CONFIG"
[[ -f "$CREDS"  ]] || err "Credentials not found: $CREDS"

# Check user doesn't already exist
jq -e --arg n "$USERNAME" '.inbounds[0].users[] | select(.name == $n)' "$CONFIG" &>/dev/null \
    && err "User '$USERNAME' already exists in config"

SERVER_IP=$(jq -r '.server_ip'        "$CREDS")
SERVER_NAME=$(jq -r '.server_name'    "$CREDS")
PUBLIC_KEY=$(jq -r '.public_key'      "$CREDS")
SHORT_ID=$(jq -r '.short_ids.primary' "$CREDS")
PORT=443

# Generate UUID
UUID=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
info "New user: $USERNAME  UUID: $UUID"

# Add user to config
TMP_CONFIG=$(mktemp)
jq --arg name "$USERNAME" --arg uuid "$UUID" --arg flow "xtls-rprx-vision" \
    '.inbounds[0].users += [{"name": $name, "uuid": $uuid, "flow": $flow}]' \
    "$CONFIG" > "$TMP_CONFIG"

sing-box check -c "$TMP_CONFIG" || err "Config validation failed after adding user"
cp "$TMP_CONFIG" "$CONFIG"
chmod 600 "$CONFIG"
rm -f "$TMP_CONFIG"

# Build link
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#VPN-${USERNAME}"

# Update credentials.json
jq --arg n "$USERNAME" --arg u "$UUID" --arg l "$LINK" \
    '.users += [{"name": $n, "uuid": $u, "link": $l}]' \
    "$CREDS" > "${CREDS}.tmp" && mv "${CREDS}.tmp" "$CREDS"
chmod 600 "$CREDS"

# Append to links file
echo "" >> /root/vpn-backup/vless-links.txt
echo "# Added $(date -u): $USERNAME" >> /root/vpn-backup/vless-links.txt
echo "$LINK" >> /root/vpn-backup/vless-links.txt

# Reload (no downtime — HUP signal)
systemctl reload singbox 2>/dev/null || systemctl restart singbox
log "Sing-box reloaded"

echo ""
echo "── ${USERNAME} ──────────────────────────────────────────────────"
echo "$LINK"
echo ""
if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$LINK"
    qrencode -o "/root/vpn-backup/qr-${USERNAME}.png" "$LINK"
    log "QR saved: /root/vpn-backup/qr-${USERNAME}.png"
fi
log "User '$USERNAME' added successfully"
