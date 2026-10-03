# Shared functions for nc-sync and config-backup. Loaded via "source".

LIB_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
CONF=${NAS_SYNC_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/linuxcnc-nas-sync/nas-sync.conf}

log() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

load_conf() {
    [ -r "$CONF" ] || die "config missing: $CONF (template: etc/nas-sync.conf.example)"
    # shellcheck source=../etc/nas-sync.conf.example
    . "$CONF"
    : "${NAS_HOST:?NAS_HOST missing in $CONF}"
    : "${NAS_USER:=}"
    [ "$NAS_HOST" = "-" ] || [ -n "$NAS_USER" ] || die "NAS_USER missing in $CONF"
    SSH_KEY=${SSH_KEY:-$HOME/.ssh/linuxcnc-nas-sync}
    BWLIMIT=${BWLIMIT:-0}
    RSYNC_SSH="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
    REMOTE="$NAS_USER@$NAS_HOST"
}

# Path on the NAS as rsync source/destination. NAS_HOST=- means a local path (for tests).
remote_path() {
    if [ "$NAS_HOST" = "-" ]; then echo "$1"; else echo "$REMOTE:$1"; fi
}

# Prevent concurrent runs. Returns 1 if another run is active.
take_lock() {
    local dir=${XDG_RUNTIME_DIR:-/tmp}
    exec 9>"$dir/linuxcnc-nas-sync.$1.lock"
    flock -n 9
}

# Refuse to send traffic over the interface of the real-time hardware (e.g. Mesa card).
check_route() {
    [ -n "${FORBIDDEN_IF:-}" ] && [ "$NAS_HOST" != "-" ] || return 0
    local dev
    dev=$(ip route get "$NAS_HOST" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    [ -n "$dev" ] || die "no route to $NAS_HOST"
    [ "$dev" != "$FORBIDDEN_IF" ] || die "route to $NAS_HOST goes via $FORBIDDEN_IF, aborting"
}

# rsync with low priority and an overall timeout.
rsync_low() {
    nice -n 19 ionice -c3 timeout "${RUN_TIMEOUT:-300}" \
        rsync -e "$RSYNC_SSH" --timeout=60 --bwlimit="$BWLIMIT" "$@"
}
