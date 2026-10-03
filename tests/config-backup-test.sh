#!/bin/bash
# Test for bin/config-backup against a local fake NAS. Needs neither a NAS nor LinuxCNC.
set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SRC=$T/configs DST=$T/nas
export XDG_RUNTIME_DIR=$T NAS_SYNC_CONF=$T/conf IDLE_CHECK=true
cat > "$NAS_SYNC_CONF" <<EOF
NAS_HOST=-
BACKUP_SOURCE=$SRC
BACKUP_TARGET=$DST
BACKUP_KEEP_DAYS=14
BACKUP_KEEP_MIN=3
EOF

fails=0
ok() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
backup() { "$HERE/../bin/config-backup" >/dev/null; }
stands() { find "$DST" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }
count() { stands | wc -l; }

mkdir -p "$SRC/machine/__pycache__" "$DST"
echo "[EMC]" > "$SRC/machine/machine.ini"
printf '#!/bin/sh\n' > "$SRC/machine/tool_db.sh"; chmod 755 "$SRC/machine/tool_db.sh"
echo 5221 > "$SRC/machine/linuxcnc.var"
echo x > "$SRC/machine/__pycache__/a.pyc"
echo x > "$SRC/machine/.vcp_persistent_data.pickle"
echo x > "$SRC/machine/tool_table.db-shm"
echo x > "$SRC/machine/sim.log"
echo x > "$SRC/machine/.halshow_watchlist"
echo x > "$SRC/machine/Thumbs.db"
echo x > "$SRC/machine/desktop.ini"
echo x > "$SRC/machine/~\$notes.txt"
echo x > "$SRC/machine/edit.TMP"
echo x > "$SRC/machine/.DS_Store"

backup
s1=$(stands | tail -1)
ok "first snapshot created and marked" '[ "$(count)" = 1 ] && [ -f "$DST/$s1.complete" ]'
ok "files backed up, executable bit kept" \
   '[ -f "$DST/$s1/machine/machine.ini" ] && [ -x "$DST/$s1/machine/tool_db.sh" ]'
ok "caches, pickle, -shm, logs, macOS/Windows metadata and temp files skipped" \
   '[ "$(find "$DST/$s1" -type f | wc -l)" = 4 ]'
ok "regular dot files kept" '[ -f "$DST/$s1/machine/.halshow_watchlist" ]'

sleep 1; backup
ok "no new snapshot without changes" '[ "$(count)" = 1 ]'

sleep 1; echo 5222 > "$SRC/machine/linuxcnc.var"; backup
s2=$(stands | tail -1)
ok "new snapshot after a change" '[ "$(count)" = 2 ] && grep -q 5222 "$DST/$s2/machine/linuxcnc.var"'
ok "unchanged file hard-linked" \
   '[ "$s1" != "$s2" ] && [ "$(stat -c %i "$DST/$s1/machine/machine.ini")" = "$(stat -c %i "$DST/$s2/machine/machine.ini")" ]'
ok "old snapshot unchanged" 'grep -q 5221 "$DST/$s1/machine/linuxcnc.var"'

sleep 1; rm "$SRC/machine/tool_db.sh"; backup
s3=$(stands | tail -1)
ok "deleted file missing from new snapshot" '[ "$(count)" = 3 ] && [ ! -e "$DST/$s3/machine/tool_db.sh" ]'

mkdir "$DST/2000-01-01_000000"
ok "aborted snapshot (no marker) deleted on next run" \
   'backup; [ ! -e "$DST/2000-01-01_000000" ]'

# Old snapshots: 5 from 20 days ago, 3 recent -> old ones deleted, recent ones kept
for i in 1 2 3 4 5; do
    d=$(date -d "-20 days -$i hours" +%Y-%m-%d_%H%M%S)
    mkdir "$DST/$d"; touch "$DST/$d.complete"
done
sleep 1; echo new > "$SRC/machine/new.txt"; backup
ok "snapshots older than 14 days deleted" '[ "$(count)" = 4 ] && [ "$(stands | head -1)" = "$s1" ]'
ok "markers of old snapshots deleted" '[ "$(find "$DST" -maxdepth 1 -name "*.complete" | wc -l)" = 4 ]'

# Only old snapshots: the newest BACKUP_KEEP_MIN are kept regardless of age
rm -rf "${DST:?}"/*
for i in 1 2 3 4 5; do
    d=$(date -d "-30 days -$i hours" +%Y-%m-%d_%H%M%S)
    mkdir -p "$DST/$d"; cp -a "$SRC/." "$DST/$d/"; touch "$DST/$d.complete"
done
backup
ok "without changes: the newest 3 old snapshots are kept" '[ "$(count)" = 3 ]'

echo new2 > "$SRC/machine/new.txt"
IDLE_CHECK=false backup
ok "no backup while LinuxCNC is busy" '[ "$(count)" = 3 ]'

[ "$fails" = 0 ] && echo "All tests passed" || echo "$fails test(s) failed"
exit $((fails > 0))
