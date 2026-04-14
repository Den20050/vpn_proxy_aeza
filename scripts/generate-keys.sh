#!/usr/bin/env bash
# Generate Reality keypair, UUIDs, short IDs → build /etc/sing-box/config.json
# Usage:
#   bash generate-keys.sh                           — init with defaults (3 users)
#   NUM_USERS=5 USER_NAMES="alice,bob,..." bash generate-keys.sh
#   SERVER_NAME="www.apple.com" bash generate-keys.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

for cmd in sing-box jq openssl curl; do
    command -v "$cmd" &>/dev/null || err "Missing dependency: $cmd"
done

# ── Settings ──────────────────────────────────────────────────────────────────
CONFIG_DIR="/etc/sing-box"
BACKUP_DIR="/root/vpn-backup"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BACKUP_CREDS="${BACKUP_DIR}/credentials.json"
BACKUP_LINKS="${BACKUP_DIR}/vless-links.txt"

NUM_USERS="${NUM_USERS:-3}"
USER_NAMES="${USER_NAMES:-}"
SERVER_NAME="${SERVER_NAME:-www.microsoft.com}"
VLESS_PORT="${VLESS_PORT:-443}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

# Five tested server_name options with notes:
# www.microsoft.com  — top-1 global traffic, very stable
# www.apple.com      — high trust, clean TLS fingerprint
# www.amazon.com     — massive traffic, rarely scrutinised
# addons.mozilla.org — smaller but reliable
# www.lovelive-anime.jp — common in community configs, but niche

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"

# ── Detect server public IP ───────────────────────────────────────────────────
SERVER_IP=$(curl -4 -fsSL --max-time 5 ifconfig.me 2>/dev/null \
    || ip -4 addr show scope global | grep inet | head -1 | awk '{print $2}' | cut -d/ -f1)
[[ -z "$SERVER_IP" ]] && err "Could not determine server public IP"
log "Server IP: $SERVER_IP"

# ── Generate Reality keypair ──────────────────────────────────────────────────
info "Generating Reality X25519 keypair..."
KEYPAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR"  | awk '/PublicKey/{print $2}')
[[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && err "Failed to parse reality keypair output:\n$KEYPAIR"
log "Keypair generated"

# ── Generate short IDs ────────────────────────────────────────────────────────
SHORT_ID_1=$(openssl rand -hex 8)   # 8 bytes — full length
SHORT_ID_2=$(openssl rand -hex 4)   # 4 bytes — shorter variant
SHORT_ID_3=$(openssl rand -hex 6)   # 6 bytes — medium variant
log "Short IDs: $SHORT_ID_1 / $SHORT_ID_2 / $SHORT_ID_3"

# ── Build user list ───────────────────────────────────────────────────────────
if [[ -z "$USER_NAMES" ]]; then
    NAMES_ARR=()
    for i in $(seq 1 "$NUM_USERS"); do
        NAMES_ARR+=("user${i}")
    done
else
    IFS=',' read -ra NAMES_ARR <<< "$USER_NAMES"
fi

info "Generating ${#NAMES_ARR[@]} users: ${NAMES_ARR[*]}"

USERS_JSON="[]"
declare -a VLESS_LINKS=()
declare -a USER_ENTRIES=()

for NAME in "${NAMES_ARR[@]}"; do
    UUID=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    USERS_JSON=$(echo "$USERS_JSON" | jq \
        --arg n "$NAME" --arg u "$UUID" --arg f "xtls-rprx-vision" \
        '. += [{"name": $n, "uuid": $u, "flow": $f}]')

    # vless:// link — URI-encode the server name
    LINK="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}"
    LINK+="?security=reality&sni=${SERVER_NAME}&fp=chrome"
    LINK+="&pbk=${PUBLIC_KEY}&sid=${SHORT_ID_1}"
    LINK+="&flow=xtls-rprx-vision&type=tcp"
    LINK+="#VPN-${NAME}"
    VLESS_LINKS+=("$LINK")

    USER_ENTRIES+=("{\"name\":\"${NAME}\",\"uuid\":\"${UUID}\",\"link\":\"${LINK}\"}")
    log "  User: $NAME  UUID: $UUID"
done

# ── Write config.json ─────────────────────────────────────────────────────────
info "Writing ${CONFIG_FILE}..."
jq -n \
    --arg server_name "$SERVER_NAME" \
    --arg private_key "$PRIVATE_KEY" \
    --argjson short_ids "[\"$SHORT_ID_1\",\"$SHORT_ID_2\",\"$SHORT_ID_3\"]" \
    --argjson users "$USERS_JSON" \
    --argjson socks_port "$SOCKS_PORT" \
    --argjson vless_port "$VLESS_PORT" \
    '{
      "log": {
        "level": "info",
        "timestamp": true,
        "output": "/var/log/sing-box/sing-box.log"
      },
      "inbounds": [
        {
          "type": "vless",
          "tag": "vless-in",
          "listen": "::",
          "listen_port": $vless_port,
          "users": $users,
          "tls": {
            "enabled": true,
            "server_name": $server_name,
            "reality": {
              "enabled": true,
              "handshake": {
                "server": $server_name,
                "server_port": 443
              },
              "private_key": $private_key,
              "short_id": $short_ids
            }
          }
        },
        {
          "type": "socks",
          "tag": "socks-bot",
          "listen": "127.0.0.1",
          "listen_port": $socks_port
        }
      ],
      "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block",  "tag": "block"}
      ],
      "route": {
        "rules": [
          {"ip_is_private": true, "outbound": "block"}
        ],
        "final": "direct"
      }
    }' > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"
log "Config written: $CONFIG_FILE"

# ── Save credentials backup ───────────────────────────────────────────────────
CREDS_JSON=$(jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg server_ip "$SERVER_IP" \
    --arg server_name "$SERVER_NAME" \
    --arg private_key "$PRIVATE_KEY" \
    --arg public_key "$PUBLIC_KEY" \
    --arg short_id_1 "$SHORT_ID_1" \
    --arg short_id_2 "$SHORT_ID_2" \
    --arg short_id_3 "$SHORT_ID_3" \
    --argjson users "$(printf '%s\n' "${USER_ENTRIES[@]}" | jq -s '.')" \
    '{
        generated_at: $generated_at,
        server_ip: $server_ip,
        server_name: $server_name,
        private_key: $private_key,
        public_key: $public_key,
        short_ids: {
            primary: $short_id_1,
            secondary: $short_id_2,
            tertiary: $short_id_3
        },
        users: $users
    }')

echo "$CREDS_JSON" > "$BACKUP_CREDS"
chmod 600 "$BACKUP_CREDS"

# ── Save vless links to plain text ─────────────────────────────────────────────
{
    echo "# VLESS links — generated $(date -u)"
    echo "# Public key: $PUBLIC_KEY"
    echo "# Short IDs: $SHORT_ID_1 / $SHORT_ID_2 / $SHORT_ID_3"
    echo ""
    for link in "${VLESS_LINKS[@]}"; do
        echo "$link"
        echo ""
    done
} > "$BACKUP_LINKS"
chmod 600 "$BACKUP_LINKS"

log "Credentials saved: $BACKUP_CREDS"

# ── Show QR codes and links ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  VLESS + Reality — Connection Links"
echo "══════════════════════════════════════════════════════════════════"

for i in "${!VLESS_LINKS[@]}"; do
    USERNAME="${NAMES_ARR[$i]}"
    LINK="${VLESS_LINKS[$i]}"

    echo ""
    echo "── ${USERNAME} ──────────────────────────────────────────────────"
    echo "$LINK"
    echo ""

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$LINK"
        QR_FILE="${BACKUP_DIR}/qr-${USERNAME}.png"
        qrencode -o "$QR_FILE" "$LINK"
        echo "  QR saved: $QR_FILE"
    else
        warn "qrencode not installed — no QR codes generated"
    fi
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Public key (share with clients): $PUBLIC_KEY"
echo "  Short IDs: $SHORT_ID_1 | $SHORT_ID_2 | $SHORT_ID_3"
echo "  All links saved: $BACKUP_LINKS"
echo "══════════════════════════════════════════════════════════════════"
