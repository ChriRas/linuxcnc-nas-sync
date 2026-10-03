#!/bin/bash
# Install linuxcnc-nas-sync for the current user (systemd user units).
# Root is only needed for missing packages (apt-get) and possibly for lingering.
#
#   ./install.sh       install / update (idempotent)
#   ./install.sh -u    remove the units (config and SSH key are kept)
#
# The timers are only enabled once the config no longer contains the example host.
set -euo pipefail
PREFIX=$(dirname "$(readlink -f "$0")")
CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/linuxcnc-nas-sync
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
KEY=$HOME/.ssh/linuxcnc-nas-sync
UNITS=(linuxcnc-nc-sync.service linuxcnc-nc-sync.timer
       linuxcnc-config-backup.service linuxcnc-config-backup.timer linuxcnc-config-backup.path)
ENABLE=(linuxcnc-nc-sync.timer linuxcnc-config-backup.timer linuxcnc-config-backup.path)

case ${1:-} in
    "" | -u) ;;
    *) echo "usage: $0 [-u]" >&2; exit 2 ;;
esac
[ "$(id -u)" != 0 ] || { echo "Run as a regular user, not as root." >&2; exit 1; }

if [ "${1:-}" = "-u" ]; then
    systemctl --user disable --now "${ENABLE[@]}" 2>/dev/null || true
    for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
    systemctl --user daemon-reload
    echo "Units removed. Config ($CONF_DIR) and SSH key ($KEY) are kept."
    exit 0
fi

# 1. Packages
need=()
for p in rsync openssh-client python3 util-linux iproute2; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ "${#need[@]}" -gt 0 ]; then
    echo "Installing missing packages: ${need[*]}"
    sudo apt-get update
    sudo apt-get install -y "${need[@]}"
fi
python3 -c 'import linuxcnc' 2>/dev/null ||
    echo "Note: Python module 'linuxcnc' not found; the state check reports 'unknown' while LinuxCNC runs."

# 2. Configuration
if [ ! -f "$CONF_DIR/nas-sync.conf" ]; then
    mkdir -p "$CONF_DIR"
    install -m 600 "$PREFIX/etc/nas-sync.conf.example" "$CONF_DIR/nas-sync.conf"
    echo "Config created: $CONF_DIR/nas-sync.conf  -> please adjust"
fi

# 3. SSH key
if [ ! -f "$KEY" ]; then
    mkdir -p -m 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C "linuxcnc-nas-sync@$(hostname)" -f "$KEY"
    echo "SSH key created. Add this public key on the NAS:"
    cat "$KEY.pub"
fi

# 4. systemd units. Keep background load off the last CPU: without isolcpus,
#    LinuxCNC (uspace) puts its real-time thread on the highest-numbered CPU.
n=$(nproc)
affinity=
[ "$n" -lt 2 ] || affinity="CPUAffinity=0-$((n - 2))"
mkdir -p "$UNIT_DIR"
for u in "${UNITS[@]}"; do
    sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@AFFINITY@|$affinity|" "$PREFIX/systemd/$u" > "$UNIT_DIR/$u"
done
systemctl --user daemon-reload

# Do not start syncing with the unedited example config: nc-sync deletes files
# in NC_TARGET that are missing on the server.
if grep -q '^NAS_HOST=nas\.example\.lan' "$CONF_DIR/nas-sync.conf"; then
    cat <<EOF

Installed, but the timers are NOT enabled yet. Next steps:
  1. Add the public key above (or in $KEY.pub) on the NAS.
  2. Edit $CONF_DIR/nas-sync.conf
  3. Test: $PREFIX/bin/nc-sync -n
  4. Run ./install.sh again to enable the timers.
EOF
    exit 0
fi
systemctl --user enable --now "${ENABLE[@]}"

# 5. Lingering: units run without a logged-in user (from boot)
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
    loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"
fi

echo "Installed. Status: systemctl --user list-timers 'linuxcnc-*'"
echo "Log:       journalctl --user -u 'linuxcnc-*' -f"
