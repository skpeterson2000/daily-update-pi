#!/bin/bash
# Installer for the daily-update self-maintaining apt updater.
# Idempotent: safe to re-run to upgrade an existing install.
#
# Usage:  sudo ./install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must run as root:  sudo ./install.sh" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"

echo "[install] script   -> /usr/local/sbin/daily-update.sh"
install -m 0755 "$SRC/daily-update.sh" /usr/local/sbin/daily-update.sh

echo "[install] units    -> /etc/systemd/system/"
install -m 0644 "$SRC"/systemd/daily-update.service        /etc/systemd/system/daily-update.service
install -m 0644 "$SRC"/systemd/daily-update.timer          /etc/systemd/system/daily-update.timer
install -m 0644 "$SRC"/systemd/daily-update-retry.service  /etc/systemd/system/daily-update-retry.service
install -m 0644 "$SRC"/systemd/daily-update-retry.timer    /etc/systemd/system/daily-update-retry.timer

echo "[install] wifi power-save drop-in -> /etc/NetworkManager/conf.d/"
if [ -d /etc/NetworkManager/conf.d ]; then
    install -m 0644 "$SRC"/networkmanager/wifi-powersave-off.conf \
        /etc/NetworkManager/conf.d/wifi-powersave-off.conf
    # Apply now if NetworkManager is running (best-effort; ignore if absent).
    systemctl reload NetworkManager 2>/dev/null || true
else
    echo "[install]   (NetworkManager/conf.d not present — skipping wifi drop-in)"
fi

echo "[install] state dir -> /var/lib/daily-update"
mkdir -p /var/lib/daily-update

echo "[install] enabling timers"
systemctl daemon-reload
systemctl enable --now daily-update.timer daily-update-retry.timer

echo
echo "[install] done. Schedule:"
systemctl list-timers 'daily-update*' --all --no-pager || true
echo
echo "Run once now (will reboot ~1 min after a successful check):"
echo "    sudo systemctl start daily-update.service"
echo "Watch logs:"
echo "    journalctl -u daily-update.service -u daily-update-retry.service -f"
