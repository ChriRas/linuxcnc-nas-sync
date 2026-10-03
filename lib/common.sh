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

# Never transferred in either direction: NAS, macOS and Windows metadata and temp files.
# rsync patterns are case-sensitive, hence the bracket expressions.
COMMON_EXCLUDES=(
    # Synology / NAS
    --exclude='@eaDir/' --exclude='#recycle/' --exclude='#snapshot/' --exclude='*@synoeastream'
    # macOS
    --exclude='.DS_Store' --exclude='._*' --exclude='.Spotlight-V100/' --exclude='.Trashes/'
    # Windows: recycle bin, system folders, thumbnail caches, folder settings
    --exclude='$RECYCLE.BIN/' --exclude='System Volume Information/'
    --exclude='[Tt]humbs.db' --exclude='[Ee]hthumbs*.db' --exclude='[Dd]esktop.ini'
    # Windows: Office owner files (~$name), temp files (~WRL0001.tmp, *.tmp)
    --exclude='~*' --exclude='*.[Tt][Mm][Pp]'
    # Windows: zone identifier streams copied as files (file.ngc:Zone.Identifier)
    --exclude='*:Zone.Identifier'
    # Unfinished downloads and editor backups
    --exclude='*.crdownload' --exclude='*.part' --exclude='*.partial' --exclude='*~'
    # LibreOffice lock files, Samba delete-on-close leftovers
    --exclude='.~lock.*#' --exclude='.smbdelete*'
)

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
