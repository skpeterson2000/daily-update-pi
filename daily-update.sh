#!/bin/bash
# Daily apt update + full-upgrade, then reboot daily after a successful check.
#
# Reboot policy: reboots once per day after the update check succeeds, even if
# no packages changed (user wants a daily reboot to flush caches/memory). A
# reboot also happens as a watchdog fallback after ~24h of GENUINELY-offline
# checks (see note_defer / check_connectivity) so a long offline stretch still
# gets its daily flush. Before rebooting, a desktop pop-up warns any local
# graphical user (see notify_desktop).
#
# This box associates to a MOBILE Starlink AP in a vehicle. NetworkManager is
# set to autoconnect with infinite retries, so it rejoins on its own whenever
# the AP is reachable; this script just defers and resumes around outages.
#
# Connectivity is judged by check_connectivity(), which is deliberately
# trustworthy: it tries several diverse hosts (both apt mirrors + a neutral
# 204 endpoint), does NOT use curl --fail (so a CDN 4xx/5xx still counts as
# "online" — getting ANY HTTP response proves the path works), and LOGS the
# real curl exit code + error for each failed attempt. An earlier single-host
# `curl -sSf https://deb.debian.org/` probe produced false "offline" verdicts
# (a transient CDN non-2xx or IPv6 hiccup tripped it) while the internet was
# fine, and it discarded stderr so the cause was invisible. Don't reintroduce
# either the single target or --fail.
#
# Behavior on no connectivity / apt failure:
#   - Sets a pending flag file at $PENDING_FLAG (persistent, survives reboot).
#   - On a genuine-offline verdict, increments a volatile deferral counter in
#     /run (resets on every boot) that drives the 24h watchdog reboot.
#   - daily-update-retry.timer polls every 15min and re-runs this script
#     (via a unit conditioned on the flag) until it succeeds.
# Logs to journald via systemd.

set -u

PENDING_FLAG=/var/lib/daily-update/pending
DEFER_COUNT_FILE=/run/daily-update/defer-count
MAX_DEFERS=96            # ~24h of retries at one per 15 min -> watchdog reboot
PROBE_URLS=(
    "https://deb.debian.org/"
    "https://archive.raspberrypi.com/"
    "https://www.google.com/generate_204"
)
PROBE_CONNECT_TIMEOUT=10 # per-attempt TCP/TLS connect budget
PROBE_TIMEOUT=15         # per-attempt total budget
PROBE_TRIES=3            # rounds over the whole target list
PROBE_GAP=5

mkdir -p "$(dirname "$PENDING_FLAG")"

log() { echo "[daily-update] $*"; }

# Pop a desktop warning into the active graphical session (Wayland/labwc or X11)
# so a local user sees the reboot coming. Launched via the USER's systemd manager
# (systemd-run --user, service mode) so it (a) survives this root oneshot exiting
# — otherwise the service cgroup would kill it instantly — and (b) returns
# immediately without blocking the reboot. Best-effort: silently no-ops if there
# is no active graphical session, or if any required tool is missing.
notify_desktop() {
    local text="$1" sid="" t a uid user rt wl
    command -v loginctl >/dev/null 2>&1 || return 0
    command -v zenity   >/dev/null 2>&1 || return 0
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        t=$(loginctl show-session "$sid" -p Type   --value 2>/dev/null)
        a=$(loginctl show-session "$sid" -p Active --value 2>/dev/null)
        if [ "$a" = "yes" ] && { [ "$t" = "wayland" ] || [ "$t" = "x11" ]; }; then
            break
        fi
        sid=""
    done
    [ -n "$sid" ] || return 0
    uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
    user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
    [ -n "$uid" ] && [ -n "$user" ] || return 0
    rt="/run/user/$uid"
    wl=$(ls "$rt" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
    [ -n "$wl" ] || wl=wayland-0
    runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="$rt" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
        WAYLAND_DISPLAY="$wl" \
        systemd-run --user -q --collect \
            --setenv=WAYLAND_DISPLAY="$wl" \
            --setenv=XDG_RUNTIME_DIR="$rt" \
            --setenv=DISPLAY=:0 \
            --setenv=XAUTHORITY="/home/$user/.Xauthority" \
            zenity --warning --no-wrap --title="OP25 — Scheduled Reboot" \
                   --text="$text" --timeout=60 \
        >/dev/null 2>&1 || true
}

# Trustworthy connectivity check. Returns 0 if ANY target answers at the HTTP
# layer (any status code — a 503 still proves the network path works), 1 only if
# every target fails at the connection level (DNS/connect/TLS/timeout) across all
# rounds. No --fail, multiple diverse hosts, and every failure is logged with
# curl's real exit code + message so an "offline" verdict explains itself.
check_connectivity() {
    local round url out rc
    for round in $(seq 1 "$PROBE_TRIES"); do
        for url in "${PROBE_URLS[@]}"; do
            out=$(curl -sS --connect-timeout "$PROBE_CONNECT_TIMEOUT" \
                       --max-time "$PROBE_TIMEOUT" -o /dev/null \
                       -w '%{http_code}' "$url" 2>&1)
            rc=$?
            if [ "$rc" -eq 0 ]; then
                log "Connectivity OK via $url (HTTP $out)."
                return 0
            fi
            log "Probe round $round/$PROBE_TRIES: $url failed (curl exit $rc: ${out})."
        done
        [ "$round" -lt "$PROBE_TRIES" ] && sleep "$PROBE_GAP"
    done
    return 1
}

# Record a genuinely-offline run and run the 24h offline watchdog. The counter
# lives in /run (tmpfs) so it auto-resets to 0 on every boot — that IS the
# "reset on reboot" mechanism. Once we've been offline MAX_DEFERS times (~24h),
# force a reboot to flush caches even while still offline; the persistent pending
# flag means the retry keeps going after the reboot.
note_defer() {
    local n
    mkdir -p "$(dirname "$DEFER_COUNT_FILE")"
    n=$(cat "$DEFER_COUNT_FILE" 2>/dev/null || echo 0)
    case "$n" in ''|*[!0-9]*) n=0;; esac
    n=$((n + 1))
    echo "$n" > "$DEFER_COUNT_FILE"
    if [ "$n" -ge "$MAX_DEFERS" ]; then
        log "Offline $n checks (~24h) — watchdog reboot to flush caches."
        notify_desktop "This OP25 system has had no network for ~24h.

It will reboot in 1 minute to refresh, then keep trying to update."
        /sbin/shutdown -r +1 "daily-update: 24h-offline watchdog reboot"
    else
        log "Offline check $n/$MAX_DEFERS since last boot."
    fi
}

if check_connectivity; then
    # Confirmed online — any prior offline streak is over, clear the counter.
    rm -f "$DEFER_COUNT_FILE"
else
    log "No connectivity after $PROBE_TRIES rounds over ${#PROBE_URLS[@]} targets; deferring."
    touch "$PENDING_FLAG"
    note_defer
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if ! apt-get update; then
    log "apt-get update failed (online); will retry."
    touch "$PENDING_FLAG"
    exit 1
fi

# dist-upgrade (not plain upgrade) so packages that need new deps or removals
# aren't silently kept back. UPGRADABLE_COUNT is the canary: if it ever
# exceeds UPGRADE_COUNT, something is still being held back.
UPGRADABLE_COUNT=$(apt list --upgradable 2>/dev/null | grep -c '/')
UPGRADE_COUNT=$(apt-get --just-print dist-upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')
log "Packages available: $UPGRADABLE_COUNT; to upgrade: $UPGRADE_COUNT"

if ! apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade; then
    log "apt-get dist-upgrade failed (online); will retry."
    touch "$PENDING_FLAG"
    exit 1
fi

# Full success — clear the pending retry flag and the deferral counter.
rm -f "$PENDING_FLAG" "$DEFER_COUNT_FILE"

# Daily reboot after a successful check, regardless of whether anything was
# upgraded. The retry units use ConditionPathExists on the (now-removed) flag,
# so a successful run happens at most once/day -> exactly one reboot/day.
if [ "$UPGRADE_COUNT" -gt 0 ]; then
    log "Upgrades applied ($UPGRADE_COUNT) — rebooting in 1 minute."
else
    log "Nothing upgraded — daily reboot anyway (cache flush) in 1 minute."
fi
notify_desktop "This OP25 system will reboot in 1 minute for daily maintenance.

Audio and scanning will stop briefly and resume automatically after the reboot."
/sbin/shutdown -r +1 "daily-update: daily reboot after update check"
