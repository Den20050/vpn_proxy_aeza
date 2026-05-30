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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/failover-common.sh
source "${SCRIPT_DIR}/lib/failover-common.sh"

for cmd in sing-box jq qrencode; do
    command -v "$cmd" &>/dev/null || err "Missing: $cmd"
done

USERNAME="$1"
CONFIG="/etc/sing-box/config.json"
CREDS="/root/vpn-backup/credentials.json"

[[ -f "$CONFIG" ]] || err "Config not found: $CONFIG"
[[ -f "$CREDS"  ]] || err "Credentials not found: $CREDS"

jq -e --arg n "$USERNAME" '.inbounds[] | select(.type=="vless") | .users[] | select(.name == $n)' "$CONFIG" &>/dev/null \
    && err "User '$USERNAME' already exists in config"

UUID=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
info "New user: $USERNAME  UUID: $UUID"

TMP_CONFIG=$(mktemp)
if failover_config_has_multi_inbound "$CONFIG"; then
    cp "$CONFIG" "$TMP_CONFIG"
    failover_add_user_all_vless "$TMP_CONFIG" "$USERNAME" "$UUID"
else
    jq --arg name "$USERNAME" --arg uuid "$UUID" --arg flow "xtls-rprx-vision" \
        '.inbounds[0].users += [{"name": $name, "uuid": $uuid, "flow": $flow}]' \
        "$CONFIG" > "$TMP_CONFIG"
fi

sing-box check -c "$TMP_CONFIG" || err "Config validation failed after adding user"
cp "$TMP_CONFIG" "$CONFIG"
chmod 600 "$CONFIG"
rm -f "$TMP_CONFIG"

jq --arg n "$USERNAME" --arg u "$UUID" \
    '.users += [{"name": $n, "uuid": $u}]' \
    "$CREDS" > "${CREDS}.tmp" && mv "${CREDS}.tmp" "$CREDS"

if jq -e '.failover.enabled == true' "$CREDS" &>/dev/null; then
    failover_regenerate_user_links "$CREDS"
    failover_write_vless_links_file "$CREDS" "/root/vpn-backup/vless-links.txt"
    failover_generate_client_config "$CREDS" "$USERNAME" "/root/vpn-backup/clients/${USERNAME}-singbox.json"
    chmod 600 "/root/vpn-backup/clients/${USERNAME}-singbox.json"
    LINK=$(jq -r --arg u "$USERNAME" '.users[] | select(.name==$u) | .link' "$CREDS")
else
    SERVER_IP=$(jq -r '.server_ip' "$CREDS")
    SERVER_NAME=$(jq -r '.server_name' "$CREDS")
    PUBLIC_KEY=$(jq -r '.public_key' "$CREDS")
    SHORT_ID=$(jq -r '.short_ids.primary' "$CREDS")
    LINK="vless://${UUID}@${SERVER_IP}:443?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#VPN-${USERNAME}"
    jq --arg n "$USERNAME" --arg l "$LINK" \
        '.users |= map(if .name == $n then . + {link: $l} else . end)' \
        "$CREDS" > "${CREDS}.tmp" && mv "${CREDS}.tmp" "$CREDS"
    echo "" >> /root/vpn-backup/vless-links.txt
    echo "# Added $(date -u): $USERNAME" >> /root/vpn-backup/vless-links.txt
    echo "$LINK" >> /root/vpn-backup/vless-links.txt
fi
chmod 600 "$CREDS"

systemctl reload singbox 2>/dev/null || systemctl restart singbox
log "Sing-box reloaded"

echo ""
echo "── ${USERNAME} ──────────────────────────────────────────────────"
LINK=$(jq -r --arg u "$USERNAME" '.users[] | select(.name==$u) | .link' "$CREDS")
echo "$LINK"
if jq -e '.failover.enabled == true' "$CREDS" &>/dev/null; then
    echo ""
    echo "  Auto-failover: /root/vpn-backup/clients/${USERNAME}-singbox.json"
fi
echo ""
if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$LINK"
    qrencode -o "/root/vpn-backup/qr-${USERNAME}.png" "$LINK"
    log "QR saved: /root/vpn-backup/qr-${USERNAME}.png"
fi
log "User '$USERNAME' added successfully"
