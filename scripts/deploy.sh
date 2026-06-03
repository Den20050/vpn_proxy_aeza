#!/usr/bin/env bash
# One-command full deployment: install Sing-box, generate keys, configure ufw,
# set up systemd, install backup cron, show vless:// links + QR codes.
#
# Usage (on a fresh Ubuntu 22.04 VPS, as root):
#   git clone https://github.com/Den20050/vpn_proxy_aeza /opt/vpn_proxy_aeza
#   cd /opt/vpn_proxy_aeza
#   bash scripts/deploy.sh
#
# Override defaults with env vars:
#   NUM_USERS=5 USER_NAMES="alice,bob,carol,dave,eve" SERVER_NAME="www.apple.com" bash scripts/deploy.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
banner() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ── Guards ────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"
[[ "$(lsb_release -si 2>/dev/null)" != "Ubuntu" ]] && warn "Tested on Ubuntu 22.04; other distros may need adjustments."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Config ────────────────────────────────────────────────────────────────────
NUM_USERS="${NUM_USERS:-3}"
USER_NAMES="${USER_NAMES:-}"
SERVER_NAME="${SERVER_NAME:-www.debian.org}"
ENABLE_FAILOVER="${ENABLE_FAILOVER:-1}"
BACKUP_DIR="/root/vpn-backup"
LOG_DIR="/var/log/sing-box"
CRON_LOG="/var/log/vpn-backup.log"

banner "Step 1/7 — System update & dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq qrencode ufw unattended-upgrades logrotate
log "Dependencies installed"

banner "Step 2/7 — Install Sing-box"

bash "${SCRIPT_DIR}/install-singbox.sh"
log "Installed: $(sing-box version | head -1)"

banner "Step 3/7 — Generate keys & config"

NUM_USERS="$NUM_USERS" USER_NAMES="$USER_NAMES" SERVER_NAME="$SERVER_NAME" \
    ENABLE_FAILOVER="$ENABLE_FAILOVER" \
    bash "${SCRIPT_DIR}/generate-keys.sh"

banner "Step 4/7 — Validate config"

sing-box check -c /etc/sing-box/config.json \
    && log "Config is valid" \
    || err "Config validation failed! Check /etc/sing-box/config.json"

banner "Step 5/7 — systemd service"

cp "${REPO_DIR}/systemd/singbox.service" /etc/systemd/system/singbox.service
systemctl daemon-reload
systemctl enable singbox
systemctl restart singbox
sleep 2
systemctl is-active singbox &>/dev/null && log "singbox.service is active" \
    || { journalctl -u singbox -n 30 --no-pager; err "singbox failed to start"; }

banner "Step 6/7 — Firewall (ufw)"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment "SSH"
ufw allow 443/tcp  comment "VLESS+Reality"
if [[ "$ENABLE_FAILOVER" == "1" ]] && [[ -f "${REPO_DIR}/config/failover-endpoints.json" ]]; then
    # shellcheck source=lib/failover-common.sh
    source "${SCRIPT_DIR}/lib/failover-common.sh"
    failover_open_ufw_ports "${REPO_DIR}/config/failover-endpoints.json"
    log "UFW: ports 22, 443, 8443-8447 (failover SNI)"
else
    log "UFW configured: only ports 22 and 443"
fi
ufw --force enable
ufw status verbose

banner "Step 7/7 — Backup cron & log rotation"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# Daily backup at 02:00
CRON_LINE="0 2 * * * bash ${SCRIPT_DIR}/backup.sh >> ${CRON_LOG} 2>&1"
(crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "$CRON_LINE") | crontab -
log "Backup cron installed: daily at 02:00"

# Log rotation for sing-box (copytruncate — no reload; avoids nightly VPN disconnects)
cat > /etc/logrotate.d/sing-box << 'EOF'
/var/log/sing-box/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
log "Log rotation configured (7 days, copytruncate)"

# ── Final status ──────────────────────────────────────────────────────────────
banner "Deployment complete"

echo -e "  ${GREEN}Service:${NC}    $(systemctl is-active singbox)"
echo -e "  ${GREEN}Config:${NC}     /etc/sing-box/config.json"
echo -e "  ${GREEN}Logs:${NC}       journalctl -u singbox -f"
echo -e "  ${GREEN}Credentials:${NC} ${BACKUP_DIR}/credentials.json"
echo -e "  ${GREEN}Links:${NC}       ${BACKUP_DIR}/vless-links.txt"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo "    systemctl status singbox"
echo "    journalctl -u singbox -f"
echo "    bash ${SCRIPT_DIR}/show-links.sh"
echo "    bash ${SCRIPT_DIR}/add-user.sh <name>"
echo "    bash ${SCRIPT_DIR}/rotate.sh --short-id"
echo ""

# Re-display links for convenience
bash "${SCRIPT_DIR}/show-links.sh"
