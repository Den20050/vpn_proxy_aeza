#!/usr/bin/env bash
# Daily backup of Sing-box config, credentials, and Redis dump.
# Designed to run from cron: 0 2 * * * bash /opt/vpn_proxy_aeza/scripts/backup.sh
set -euo pipefail

BACKUP_ROOT="/root/backups"
SOURCE_DIRS=("/etc/sing-box" "/root/vpn-backup")
OPTIONAL_FILES=("/var/lib/redis/dump.rdb")

TS=$(date +%Y-%m-%d)
DAY_DIR="${BACKUP_ROOT}/daily/${TS}"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
ARCHIVE="${DAY_DIR}/vpn-backup-${TS}.tar.gz"

mkdir -p "$DAY_DIR" "$WEEKLY_DIR"

# ── Collect files ──────────────────────────────────────────────────────────────
COLLECT=()
for d in "${SOURCE_DIRS[@]}"; do
    [[ -d "$d" ]] && COLLECT+=("$d")
done
for f in "${OPTIONAL_FILES[@]}"; do
    [[ -f "$f" ]] && COLLECT+=("$f")
done

[[ ${#COLLECT[@]} -eq 0 ]] && echo "[!] Nothing to back up" && exit 1

tar -czf "$ARCHIVE" "${COLLECT[@]}" 2>/dev/null
chmod 600 "$ARCHIVE"

SIZE=$(du -sh "$ARCHIVE" | cut -f1)
echo "[✓] $(date -u +%Y-%m-%dT%H:%M:%SZ) — Backup created: $ARCHIVE ($SIZE)"

# ── Weekly copy (every Sunday) ────────────────────────────────────────────────
if [[ "$(date +%u)" == "7" ]]; then
    WEEK=$(date +%Y-W%V)
    cp "$ARCHIVE" "${WEEKLY_DIR}/vpn-backup-${WEEK}.tar.gz"
    echo "[✓] Weekly backup saved: ${WEEKLY_DIR}/vpn-backup-${WEEK}.tar.gz"
fi

# ── Retention: keep last 7 daily, 4 weekly ────────────────────────────────────
find "${BACKUP_ROOT}/daily"  -maxdepth 1 -type d | sort | head -n -7 | xargs -r rm -rf
find "${BACKUP_ROOT}/weekly" -maxdepth 1 -type f | sort | head -n -4 | xargs -r rm -f

echo "[✓] Retention applied: 7 daily / 4 weekly"
