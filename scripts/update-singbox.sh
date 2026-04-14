#!/usr/bin/env bash
# Update Sing-box to the latest release with zero-downtime reload.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Current version
CURRENT=$(sing-box version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
info "Current version: $CURRENT"

# Latest version
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)
LATEST="${LATEST_TAG#v}"
info "Latest version:  $LATEST"

if [[ "$CURRENT" == "$LATEST" ]]; then
    log "Already on latest version ($CURRENT). Nothing to do."
    exit 0
fi

warn "Updating: $CURRENT → $LATEST"

# Validate current config before update
sing-box check -c /etc/sing-box/config.json \
    && log "Pre-update config validation passed" \
    || err "Config is invalid before update — fix it first"

# Install new version
bash "${SCRIPT_DIR}/install-singbox.sh"

# Restart
systemctl restart singbox
sleep 2
systemctl is-active singbox &>/dev/null \
    && log "Sing-box $LATEST is running" \
    || { journalctl -u singbox -n 30 --no-pager; err "Sing-box failed after update"; }

log "Update complete: $CURRENT → $LATEST"
