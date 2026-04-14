#!/usr/bin/env bash
# Rotate Reality short_id and/or server_name without user UUID changes.
# Usage:
#   bash rotate.sh --short-id                   — rotate short IDs only
#   bash rotate.sh --server-name www.apple.com  — change server_name
#   bash rotate.sh --all                        — rotate everything
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root"
[[ $# -eq 0 ]]    && err "Usage: $0 --short-id | --server-name <name> | --all"

for cmd in sing-box jq openssl; do
    command -v "$cmd" &>/dev/null || err "Missing: $cmd"
done

CONFIG="/etc/sing-box/config.json"
CREDS="/root/vpn-backup/credentials.json"
BACKUP_DIR="/root/vpn-backup"

[[ -f "$CONFIG" ]] || err "Config not found: $CONFIG"
[[ -f "$CREDS"  ]] || err "Credentials not found: $CREDS"

ROTATE_SHORT_ID=false
ROTATE_SERVER_NAME=false
NEW_SERVER_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --short-id)      ROTATE_SHORT_ID=true ;;
        --server-name)   ROTATE_SERVER_NAME=true; NEW_SERVER_NAME="${2:-}"; shift ;;
        --all)           ROTATE_SHORT_ID=true; ROTATE_SERVER_NAME=true ;;
        *) err "Unknown option: $1" ;;
    esac
    shift
done

# ── Backup current config ─────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
cp "$CONFIG" "${BACKUP_DIR}/config.json.bak.${TS}"
log "Backup saved: ${BACKUP_DIR}/config.json.bak.${TS}"

UPDATED_CONFIG="$CONFIG"

# ── Rotate short IDs ──────────────────────────────────────────────────────────
if $ROTATE_SHORT_ID; then
    info "Rotating short IDs..."
    OLD_SHORT_ID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONFIG")
    NEW_SHORT_ID_1=$(openssl rand -hex 8)
    NEW_SHORT_ID_2=$(openssl rand -hex 4)
    NEW_SHORT_ID_3=$(openssl rand -hex 6)

    TMP=$(mktemp)
    jq --argjson ids "[\"$NEW_SHORT_ID_1\",\"$NEW_SHORT_ID_2\",\"$NEW_SHORT_ID_3\"]" \
        '.inbounds[0].tls.reality.short_id = $ids' "$CONFIG" > "$TMP"
    mv "$TMP" "$CONFIG"

    # Update credentials backup
    jq --arg s1 "$NEW_SHORT_ID_1" --arg s2 "$NEW_SHORT_ID_2" --arg s3 "$NEW_SHORT_ID_3" \
        --arg rotated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.short_ids = {primary: $s1, secondary: $s2, tertiary: $s3} | .last_rotation = $rotated_at' \
        "$CREDS" > "${CREDS}.tmp" && mv "${CREDS}.tmp" "$CREDS"

    warn "⚠  Short IDs changed — ALL clients must update their connection configs!"
    warn "   Old primary: $OLD_SHORT_ID"
    log  "   New primary: $NEW_SHORT_ID_1"
    log  "   New IDs: $NEW_SHORT_ID_1 | $NEW_SHORT_ID_2 | $NEW_SHORT_ID_3"
fi

# ── Rotate server_name ────────────────────────────────────────────────────────
if $ROTATE_SERVER_NAME; then
    if [[ -z "$NEW_SERVER_NAME" ]]; then
        # Suggest options if none provided
        echo ""
        echo "Available server_name options:"
        echo "  1) www.microsoft.com   (default, very stable)"
        echo "  2) www.apple.com"
        echo "  3) www.amazon.com"
        echo "  4) addons.mozilla.org"
        echo "  5) www.lovelive-anime.jp"
        echo ""
        read -rp "Enter new server_name: " NEW_SERVER_NAME
    fi
    [[ -z "$NEW_SERVER_NAME" ]] && err "server_name cannot be empty"

    OLD_SERVER_NAME=$(jq -r '.inbounds[0].tls.server_name' "$CONFIG")
    info "Changing server_name: $OLD_SERVER_NAME → $NEW_SERVER_NAME"

    TMP=$(mktemp)
    jq --arg sn "$NEW_SERVER_NAME" '
        .inbounds[0].tls.server_name = $sn |
        .inbounds[0].tls.reality.handshake.server = $sn
    ' "$CONFIG" > "$TMP"
    mv "$TMP" "$CONFIG"

    # Update credentials backup
    jq --arg sn "$NEW_SERVER_NAME" '.server_name = $sn' \
        "$CREDS" > "${CREDS}.tmp" && mv "${CREDS}.tmp" "$CREDS"

    warn "⚠  server_name changed: $OLD_SERVER_NAME → $NEW_SERVER_NAME"
    warn "   Clients must update SNI in their connection settings!"
fi

chmod 600 "$CONFIG" "$CREDS"

# ── Validate & restart ────────────────────────────────────────────────────────
sing-box check -c "$CONFIG" || err "Config validation failed! Restoring backup..."

systemctl reload singbox 2>/dev/null || systemctl restart singbox
sleep 1
systemctl is-active singbox &>/dev/null \
    && log "Sing-box restarted successfully" \
    || err "Sing-box failed to restart — check: journalctl -u singbox -n 30"

# ── Show updated links ────────────────────────────────────────────────────────
SERVER_IP=$(jq -r '.server_ip'      "$CREDS")
SN=$(jq -r '.server_name'           "$CREDS")
PK=$(jq -r '.public_key'            "$CREDS")
SID=$(jq -r '.short_ids.primary'    "$CREDS")

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Updated VLESS links (new short_id / server_name)"
echo "══════════════════════════════════════════════════════════════════"

jq -r '.users[] | "\(.name)|\(.uuid)"' "$CREDS" | while IFS='|' read -r NAME UUID; do
    LINK="vless://${UUID}@${SERVER_IP}:443?security=reality&sni=${SN}&fp=chrome&pbk=${PK}&sid=${SID}&flow=xtls-rprx-vision&type=tcp#VPN-${NAME}"
    echo ""
    echo "── ${NAME}: $LINK"
    command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$LINK"
done

echo ""
log "Rotation complete. Send updated links to affected users."
