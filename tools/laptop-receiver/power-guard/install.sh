#!/usr/bin/env bash
# Installs the power guard as a user timer — no root, no system files.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$units"
install -m 0644 "$here/diktafon-power-guard.service" "$units/"
install -m 0644 "$here/diktafon-power-guard.timer" "$units/"
systemctl --user daemon-reload
systemctl --user enable --now diktafon-power-guard.timer
systemctl --user list-timers diktafon-power-guard.timer --all

cat <<'MSG'

Installed. The guard checks every minute: on mains it starts the receiver
and its tunnel, on battery it stops them.

  systemctl --user status diktafon-power-guard.timer   # is it armed
  ./diktafon-power-guard start                         # force it up now
  ./diktafon-power-guard stop                          # force it down

For an instant reaction to the cable, see 99-diktafon-power.rules.
MSG
