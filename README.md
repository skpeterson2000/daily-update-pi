# daily-update — self-maintaining apt updater + daily reboot for Raspberry Pi

A small, robust systemd-based job that keeps a headless / intermittently-connected
Raspberry Pi up to date and reboots it once a day to flush caches — built and
hardened on a real Pi that connects through a **mobile Starlink AP** (so it has to
tolerate the internet coming and going for hours or days).

## What it does

Every day at **04:00** (randomized ±5 min) it:

1. **Checks connectivity** with a trustworthy, self-logging probe (see below).
2. If offline, **defers** — sets a flag and a 15-minute retry timer takes over until
   the link returns. Nothing is forced; it just waits and resumes.
3. If online, runs `apt-get update` + `apt-get dist-upgrade` (full-upgrade, so
   nothing is silently held back), with non-interactive conffile handling.
4. **Reboots** ~1 minute later — every day, even if nothing was upgraded (a
   deliberate daily cache/memory flush). A desktop pop-up warns any local user first.

## Why it's more than a cron one-liner

These behaviours were each added to fix a real failure mode:

- **Trustworthy connectivity check.** Probes several diverse hosts (both apt mirrors
  plus a neutral `204` endpoint), does **not** use `curl --fail` (a CDN `503` still
  proves the path works), and **logs curl's exit code + error** on every failure.
  An earlier single-host `curl -sSf` probe produced false "offline" verdicts (a
  transient CDN non-2xx tripped it) and discarded the error so the cause was
  invisible. Now an "offline" verdict explains itself (exit 6 = DNS, 28 = timeout,
  35/60 = TLS/clock, …).
- **Defer + resume.** On no connectivity it sets `/var/lib/daily-update/pending`;
  `daily-update-retry.timer` polls every 15 min and the retry service is gated on
  that flag (`ConditionPathExists`), so it's a near-zero-cost no-op when nothing is
  pending. The update completes within ~15 min of the link returning.
- **`dist-upgrade`, not `upgrade`.** Plain `upgrade` silently keeps back anything
  needing new deps/removals. A canary log line (`Packages available: N; to
  upgrade: M`) makes any held-back drift visible.
- **Daily reboot even with 0 upgrades.** Gated on a *successful* check, so it never
  reboots blindly while it couldn't even verify state.
- **24h offline watchdog.** Because the daily reboot is gated on success, a long
  offline stretch would otherwise skip the daily flush. A counter in `/run`
  (tmpfs — auto-resets on every boot) counts consecutive *genuinely-offline* checks;
  after ~24h it reboots anyway to flush caches, then keeps retrying. It only counts
  real offline verdicts, so it can never reboot a connected box.
- **Wifi power-save disabled.** `networkmanager/wifi-powersave-off.conf` stops the
  radio sleeping when idle, which otherwise made cold-radio probes time out on
  unattended runs.
- **Desktop reboot warning.** Best-effort `zenity` pop-up into the active Wayland/X11
  session via the user's own systemd manager (so it survives the root job exiting
  and doesn't block the reboot). Silently no-ops on headless systems.

## Install

```sh
git clone <your-repo-url> daily-update-pi
cd daily-update-pi
sudo ./install.sh
```

Run once immediately (note: reboots ~1 min after a successful check):

```sh
sudo systemctl start daily-update.service
journalctl -u daily-update.service -u daily-update-retry.service -f
```

## Configure

- **Reboot time:** edit `OnCalendar=*-*-* 04:00:00` in
  `systemd/daily-update.timer` (re-run `install.sh` or
  `systemctl daemon-reload`).
- **Don't want the daily reboot when nothing changed?** In `daily-update.sh`, make
  the final `shutdown` conditional on `[ "$UPGRADE_COUNT" -gt 0 ]`.
- **Probe targets / timeouts / 24h threshold:** the `PROBE_URLS`, `PROBE_*`, and
  `MAX_DEFERS` variables at the top of `daily-update.sh`.

## Files

| Path | Purpose |
|------|---------|
| `daily-update.sh` | the job itself → `/usr/local/sbin/` |
| `systemd/daily-update.{service,timer}` | the 04:00 daily run |
| `systemd/daily-update-retry.{service,timer}` | 15-min retry while offline |
| `networkmanager/wifi-powersave-off.conf` | disable wifi power-save |
| `install.sh` / `uninstall.sh` | idempotent (un)installer |

## Requirements

Raspberry Pi OS / Debian (bookworm+), systemd, `curl`. `zenity` is optional (only
for the desktop pop-up). Tested on Raspberry Pi 5 (bookworm).

## Uninstall

```sh
sudo ./uninstall.sh        # keeps the wifi power-save drop-in
sudo ./uninstall.sh --all  # removes that too
```
