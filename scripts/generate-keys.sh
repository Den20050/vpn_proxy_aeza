#!/usr/bin/env bash
# Generate Reality keypair, UUIDs, short IDs → build /etc/sing-box/config.json
# Usage:
#   bash generate-keys.sh                           — init with defaults (3 users)
#   NUM_USERS=5 USER_NAMES="alice,bob,..." bash generate-keys.sh
#   SERVER_NAME="www.apple.com" bash generate-keys.sh
#   ENABLE_FAILOVER=0 bash generate-keys.sh         — single SNI only
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/failover-common.sh
source "${SCRIPT_DIR}/lib/failover-common.sh"

for cmd in sing-box jq openssl curl; do
    command -v "$cmd" &>/dev/null || err "Missing dependency: $cmd"
done

# ── Settings ──────────────────────────────────────────────────────────────────
CONFIG_DIR="/etc/sing-box"
BACKUP_DIR="/root/vpn-backup"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BACKUP_CREDS="${BACKUP_DIR}/credentials.json"
BACKUP_LINKS="${BACKUP_DIR}/vless-links.txt"
ENDPOINTS_FILE="$(failover_endpoints_file)"

NUM_USERS="${NUM_USERS:-3}"
USER_NAMES="${USER_NAMES:-}"
SERVER_NAME="${SERVER_NAME:-www.debian.org}"
VLESS_PORT="${VLESS_PORT:-443}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

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
SHORT_ID_1=$(openssl rand -hex 8)
SHORT_ID_2=$(openssl rand -hex 4)
SHORT_ID_3=$(openssl rand -hex 6)
SHORT_IDS_JSON="[\"$SHORT_ID_1\",\"$SHORT_ID_2\",\"$SHORT_ID_3\"]"
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
declare -a USER_ENTRIES=()

for NAME in "${NAMES_ARR[@]}"; do
    UUID=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    USERS_JSON=$(echo "$USERS_JSON" | jq \
        --arg n "$NAME" --arg u "$UUID" --arg f "xtls-rprx-vision" \
        '. += [{"name": $n, "uuid": $u, "flow": $f}]')
    USER_ENTRIES+=("{\"name\":\"${NAME}\",\"uuid\":\"${UUID}\"}")
    log "  User: $NAME  UUID: $UUID"
done

# ── Write config.json ─────────────────────────────────────────────────────────
info "Writing ${CONFIG_FILE}..."

if failover_enabled && [[ -f "$ENDPOINTS_FILE" ]]; then
    PRIMARY_SN=$(jq -r '.endpoints[0].server_name' "$ENDPOINTS_FILE")
    SERVER_NAME="$PRIMARY_SN"
    failover_merge_server_config "$USERS_JSON" "$PRIVATE_KEY" "$SHORT_IDS_JSON" "$ENDPOINTS_FILE" "$SOCKS_PORT" \
        > "$CONFIG_FILE"
    log "Config with failover SNI: $(jq -r '[.inbounds[]|select(.type=="vless")|.tls.server_name]|join(", ")' "$CONFIG_FILE")"
else
    jq -n \
        --arg server_name "$SERVER_NAME" \
        --arg private_key "$PRIVATE_KEY" \
        --argjson short_ids "$SHORT_IDS_JSON" \
        --argjson users "$USERS_JSON" \
        --argjson socks_port "$SOCKS_PORT" \
        --argjson vless_port "$VLESS_PORT" \
        '{
          log: {level: "warn", timestamp: true, output: "/var/log/sing-box/sing-box.log"},
          inbounds: [{
            type: "vless", tag: "vless-in", listen: "::", listen_port: $vless_port,
            users: $users,
            tls: {
              enabled: true, server_name: $server_name,
              reality: {
                enabled: true,
                handshake: {server: $server_name, server_port: 443},
                private_key: $private_key, short_id: $short_ids
              }
            }
          }, {
            type: "socks", tag: "socks-bot", listen: "127.0.0.1", listen_port: $socks_port
          }],
          outbounds: [{type: "direct", tag: "direct"}, {type: "block", tag: "block"}],
          route: {rules: [{ip_is_private: true, outbound: "block"}], final: "direct"}
        }' > "$CONFIG_FILE"
fi

chmod 600 "$CONFIG_FILE"
log "Config written: $CONFIG_FILE"

# ── Save credentials backup ───────────────────────────────────────────────────
FAILOVER_JSON="null"
if failover_enabled && [[ -f "$ENDPOINTS_FILE" ]]; then
    FAILOVER_JSON=$(failover_build_creds_failover_json "$ENDPOINTS_FILE")
fi

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
    --argjson failover "$FAILOVER_JSON" \
    '{
        generated_at: $generated_at,
        server_ip: $server_ip,
        server_name: $server_name,
        private_key: $private_key,
        public_key: $public_key,
        short_ids: {primary: $short_id_1, secondary: $short_id_2, tertiary: $short_id_3},
        failover: $failover,
        users: $users
    }')

echo "$CREDS_JSON" > "$BACKUP_CREDS"
chmod 600 "$BACKUP_CREDS"

if [[ "$FAILOVER_JSON" != "null" ]]; then
    failover_regenerate_user_links "$BACKUP_CREDS"
    failover_write_vless_links_file "$BACKUP_CREDS" "$BACKUP_LINKS"
    mkdir -p "${BACKUP_DIR}/clients"
    failover_generate_all_client_configs "$BACKUP_CREDS" "${BACKUP_DIR}/clients"
else
    {
        echo "# VLESS links — generated $(date -u)"
        echo "# Public key: $PUBLIC_KEY"
        echo "# Short IDs: $SHORT_ID_1 / $SHORT_ID_2 / $SHORT_ID_3"
        echo ""
        jq -r '.users[] | "\(.name): vless://\(.uuid)@'"$SERVER_IP"':'"$VLESS_PORT"'?security=reality&sni='"$SERVER_NAME"'&fp=chrome&pbk='"$PUBLIC_KEY"'&sid='"$SHORT_ID_1"'&flow=xtls-rprx-vision&type=tcp#VPN-\(.name)"' "$BACKUP_CREDS" 2>/dev/null || true
        for NAME in "${NAMES_ARR[@]}"; do
            UUID=$(echo "$USERS_JSON" | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .uuid')
            echo "vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID_1}&flow=xtls-rprx-vision&type=tcp#VPN-${NAME}"
            echo ""
        done
    } > "$BACKUP_LINKS"
fi
chmod 600 "$BACKUP_LINKS"

log "Credentials saved: $BACKUP_CREDS"

# ── Show QR codes and links ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  VLESS + Reality — Connection Links"
echo "══════════════════════════════════════════════════════════════════"

if jq -e '.failover.enabled == true' "$BACKUP_CREDS" &>/dev/null; then
    jq -r '.users[] | .name + "|" + .link' "$BACKUP_CREDS" | while IFS='|' read -r USERNAME LINK; do
        echo ""
        echo "── ${USERNAME} (primary) ─────────────────────────────────────────"
        echo "$LINK"
        echo "  Auto-failover client: ${BACKUP_DIR}/clients/${USERNAME}-singbox.json"
        if command -v qrencode &>/dev/null; then
            qrencode -t ANSIUTF8 "$LINK"
            qrencode -o "${BACKUP_DIR}/qr-${USERNAME}.png" "$LINK"
        fi
    done
else
    for i in "${!NAMES_ARR[@]}"; do
        USERNAME="${NAMES_ARR[$i]}"
        UUID=$(echo "$USERS_JSON" | jq -r --arg n "$USERNAME" '.[] | select(.name==$n) | .uuid')
        LINK="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID_1}&flow=xtls-rprx-vision&type=tcp#VPN-${USERNAME}"
        echo ""
        echo "── ${USERNAME} ──────────────────────────────────────────────────"
        echo "$LINK"
        if command -v qrencode &>/dev/null; then
            qrencode -t ANSIUTF8 "$LINK"
            qrencode -o "${BACKUP_DIR}/qr-${USERNAME}.png" "$LINK"
        fi
    done
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Public key (share with clients): $PUBLIC_KEY"
echo "  Short IDs: $SHORT_ID_1 | $SHORT_ID_2 | $SHORT_ID_3"
if jq -e '.failover.enabled == true' "$BACKUP_CREDS" &>/dev/null; then
    echo "  Failover SNIs: $(jq -r '[.failover.endpoints[].server_name]|join(", ")' "$BACKUP_CREDS")"
    echo "  Client configs: ${BACKUP_DIR}/clients/"
fi
echo "  All links saved: $BACKUP_LINKS"
echo "══════════════════════════════════════════════════════════════════"
