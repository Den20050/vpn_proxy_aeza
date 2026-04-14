#!/usr/bin/env bash
# Full server hardening:
#   1. SSH hardening (disable password auth, limit retries, timeouts)
#   2. fail2ban (SSH brute-force protection)
#   3. UFW rate-limiting for SSH
#   4. sysctl network & kernel hardening
#   5. Automatic security updates (unattended-upgrades)
#   6. File & directory permissions audit
#   7. Remove dangerous legacy packages
#   8. ulimits for sing-box (DoS resilience)
#   9. Login banner
#
# Safe to re-run (idempotent). Does NOT change SSH port — SSH stays on 22.
# WARNING: Disables password SSH auth. Make sure your key works before running!
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info()   { echo -e "${BLUE}[→]${NC} $*"; }
banner() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

# ── Verify SSH key auth works BEFORE disabling password ───────────────────────
# We check that at least one authorized_keys file exists system-wide.
KEY_FOUND=false
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] && KEY_FOUND=true && break
done
$KEY_FOUND || err "No authorized_keys found! Add your SSH public key first to avoid lockout."

banner "Step 1/8 — SSH hardening"

SSHD_CONF="/etc/ssh/sshd_config"
cp "${SSHD_CONF}" "${SSHD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"

# Apply settings — use sed to update existing or append if missing
apply_ssh() {
    local key="$1" val="$2"
    if grep -qE "^#?${key}" "$SSHD_CONF"; then
        sed -i "s|^#\?${key}.*|${key} ${val}|" "$SSHD_CONF"
    else
        echo "${key} ${val}" >> "$SSHD_CONF"
    fi
}

apply_ssh PasswordAuthentication     no
apply_ssh PermitRootLogin            prohibit-password   # root key-only (already effectively off)
apply_ssh MaxAuthTries               3
apply_ssh MaxSessions                5
apply_ssh LoginGraceTime             30
apply_ssh X11Forwarding              no
apply_ssh AllowTcpForwarding         no    # disable SSH tunneling (sing-box handles VPN)
apply_ssh ClientAliveInterval        300
apply_ssh ClientAliveCountMax        2
apply_ssh UseDNS                     no    # faster logins
apply_ssh Banner                     /etc/ssh/banner

# Validate config before restarting
sshd -t || err "sshd config validation failed — check ${SSHD_CONF}"
systemctl reload sshd
log "SSH hardened: password auth disabled, MaxAuthTries=3, timeouts set"

banner "Step 2/8 — fail2ban"

apt-get install -y -qq fail2ban

# Main jail config
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 4
bantime  = 2h
findtime = 10m
EOF

systemctl enable fail2ban
systemctl restart fail2ban
sleep 1
systemctl is-active fail2ban &>/dev/null && log "fail2ban active (SSH jail enabled)" \
    || warn "fail2ban failed to start — check: journalctl -u fail2ban"

banner "Step 3/8 — UFW rate-limiting for SSH"

# Rate limit SSH: max 6 connections in 30 seconds per IP
ufw limit 22/tcp comment "SSH rate-limit"
ufw reload
log "UFW: SSH rate-limited (6 conn / 30s per IP)"

banner "Step 4/8 — sysctl: network & kernel hardening"

cat > /etc/sysctl.d/99-vpn-harden.conf << 'EOF'
# ── SYN flood protection ──────────────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# ── Reverse path filtering (anti-spoofing) ────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ── Block ICMP broadcast (Smurf attacks) ─────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── Disable IP source routing ─────────────────────────────────────────────────
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# ── Disable ICMP redirects ────────────────────────────────────────────────────
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ── Log martian packets (suspicious source IPs) ───────────────────────────────
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ── Kernel hardening ──────────────────────────────────────────────────────────
kernel.randomize_va_space = 2          # full ASLR
kernel.dmesg_restrict = 1             # restrict dmesg to root
kernel.kptr_restrict = 2              # hide kernel pointers from /proc
kernel.sysrq = 0                      # disable SysRq
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# ── Connection tracking (NAT for VPN traffic) ─────────────────────────────────
net.netfilter.nf_conntrack_max = 131072
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established = 3600

# ── Performance tuning for VPN workload ──────────────────────────────────────
net.core.somaxconn = 4096
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

sysctl -p /etc/sysctl.d/99-vpn-harden.conf 2>/dev/null | grep -c "=" | xargs -I{} log "Applied {} sysctl parameters"

banner "Step 5/8 — Automatic security updates"

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades &>/dev/null || true
log "Automatic security updates: enabled (daily, no auto-reboot)"

banner "Step 6/8 — File & directory permissions"

# Sing-box config and credentials
[[ -f /etc/sing-box/config.json ]]     && chmod 600 /etc/sing-box/config.json     && log "600 /etc/sing-box/config.json"
[[ -d /etc/sing-box ]]                 && chmod 700 /etc/sing-box                  && log "700 /etc/sing-box/"
[[ -d /root/vpn-backup ]]              && chmod 700 /root/vpn-backup               && log "700 /root/vpn-backup/"
[[ -f /root/vpn-backup/credentials.json ]] && chmod 600 /root/vpn-backup/credentials.json
[[ -f /root/vpn-backup/vless-links.txt ]]  && chmod 600 /root/vpn-backup/vless-links.txt
for qr in /root/vpn-backup/qr-*.png; do [[ -f "$qr" ]] && chmod 600 "$qr"; done
log "QR files and credentials locked to 600"

# SSH
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
log "SSH directory permissions: 700/.ssh, 600/authorized_keys"

# Repo scripts — executable but not world-writable
chmod 750 /opt/vpn_proxy_aeza/scripts/*.sh 2>/dev/null || true
log "Scripts: 750 /opt/vpn_proxy_aeza/scripts/*.sh"

# Restrict crontab access
chmod 600 /etc/cron.d/* 2>/dev/null || true
chmod 700 /var/spool/cron/crontabs 2>/dev/null || true

banner "Step 7/8 — Remove dangerous legacy packages"

for pkg in telnet rsh-client rsh-redone-client nis talk talkd; do
    if dpkg -l "$pkg" &>/dev/null; then
        apt-get purge -y -qq "$pkg"
        log "Removed: $pkg"
    fi
done
log "Legacy packages check done"

banner "Step 8/8 — Login banner & final touches"

cat > /etc/ssh/banner << 'EOF'

  ╔══════════════════════════════════════════════════════════╗
  ║  AUTHORIZED ACCESS ONLY                                  ║
  ║  All activity is logged and monitored.                   ║
  ║  Unauthorized access will be prosecuted.                 ║
  ╚══════════════════════════════════════════════════════════╝

EOF

cat > /etc/motd << 'EOF'
EOF
log "Login banner set"

# Restrict /proc access (hide processes of other users)
if ! grep -q "hidepid=2" /etc/fstab; then
    sed -i 's|^\(proc\s.*defaults\)\(.*\)|\1,hidepid=2\2|' /etc/fstab
    mount -o remount,hidepid=2 /proc 2>/dev/null || warn "/proc remount requires reboot to take effect"
    log "hidepid=2 added to /proc mount options"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Hardening complete"

echo -e "  ${GREEN}SSH:${NC}            password auth disabled, MaxAuthTries=3"
echo -e "  ${GREEN}fail2ban:${NC}       active (SSH: ban after 4 attempts, 2h ban)"
echo -e "  ${GREEN}UFW:${NC}            SSH rate-limited (6 conn/30s)"
echo -e "  ${GREEN}sysctl:${NC}         SYN cookies, anti-spoofing, ASLR, kernel hardening"
echo -e "  ${GREEN}Auto-updates:${NC}   security patches applied daily"
echo -e "  ${GREEN}Permissions:${NC}    sensitive files locked to 600/700"
echo -e "  ${GREEN}Banner:${NC}         login warning active"
echo ""
echo -e "  ${YELLOW}Check fail2ban status:${NC}   fail2ban-client status sshd"
echo -e "  ${YELLOW}Check banned IPs:${NC}        fail2ban-client status sshd | grep 'Banned IP'"
echo -e "  ${YELLOW}Unban an IP:${NC}             fail2ban-client set sshd unbanip <IP>"
echo ""
warn "Reboot recommended to fully apply sysctl and /proc changes."
