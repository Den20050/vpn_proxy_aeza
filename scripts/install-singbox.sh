#!/usr/bin/env bash
# Install or upgrade Sing-box to the latest release from GitHub.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $*"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

INSTALL_DIR="/usr/local/bin"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Detect latest version ────────────────────────────────────────────────────
info "Detecting latest Sing-box version..."
LATEST=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)
[[ -z "$LATEST" ]] && err "Could not detect latest Sing-box version. Check your internet connection."
VERSION="${LATEST#v}"

# ── Check if already installed at same version ───────────────────────────────
if command -v sing-box &>/dev/null; then
    CURRENT=$(sing-box version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if [[ "$CURRENT" == "$VERSION" ]]; then
        log "Sing-box $VERSION is already installed."
        exit 0
    fi
    warn "Upgrading sing-box: $CURRENT → $VERSION"
else
    info "Installing Sing-box $VERSION..."
fi

# ── Download ─────────────────────────────────────────────────────────────────
ARCH="amd64"
TARBALL="sing-box-${VERSION}-linux-${ARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/${TARBALL}"

info "Downloading: $URL"
curl -fsSL -o "${TMP_DIR}/${TARBALL}" "$URL"

# ── Verify checksum if available ─────────────────────────────────────────────
SHA_URL="${URL}.sha256sum"
if curl -fsSL -o "${TMP_DIR}/${TARBALL}.sha256sum" "$SHA_URL" 2>/dev/null; then
    info "Verifying checksum..."
    (cd "$TMP_DIR" && sha256sum -c "${TARBALL}.sha256sum")
    log "Checksum OK"
else
    warn "No checksum file found, skipping verification."
fi

# ── Install ───────────────────────────────────────────────────────────────────
tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
BINARY=$(find "$TMP_DIR" -name "sing-box" -type f | head -1)
[[ -z "$BINARY" ]] && err "sing-box binary not found in archive"

install -m 755 "$BINARY" "${INSTALL_DIR}/sing-box"

# ── Create config dir ─────────────────────────────────────────────────────────
mkdir -p /etc/sing-box /var/log/sing-box

log "Sing-box $(sing-box version | head -1) installed at ${INSTALL_DIR}/sing-box"
