#!/bin/bash
# Uninstaller for the daily-update self-maintaining apt updater.
# Leaves the wifi power-save drop-in in place by default (it's harmless and
# often still wanted); pass --all to remove that too.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root:  sudo ./uninstall.sh [--all]" >&2
    exit 1
fi

systemctl disable --now daily-update.timer daily-update-retry.timer 2>/dev/null || true

rm -f /etc/systemd/system/daily-update.service \
      /etc/systemd/system/daily-update.timer \
      /etc/systemd/system/daily-update-retry.service \
      /etc/systemd/system/daily-update-retry.timer
systemctl daemon-reload

rm -f /usr/local/sbin/daily-update.sh
rm -rf /var/lib/daily-update
rm -f /run/daily-update/defer-count 2>/dev/null || true
rm -f /var/log/daily-update.log 2>/dev/null || true

if [ "${1:-}" = "--all" ]; then
    rm -f /etc/NetworkManager/conf.d/wifi-powersave-off.conf
    systemctl reload NetworkManager 2>/dev/null || true
    echo "[uninstall] removed wifi power-save drop-in too"
fi

echo "[uninstall] done."
