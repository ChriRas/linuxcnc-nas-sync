#!/bin/bash
# Test for bin/nc-sync against a local fake NAS. Needs neither a NAS nor LinuxCNC.
set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SRC=$T/nas DST=$T/nc_files
export XDG_RUNTIME_DIR=$T NAS_SYNC_CONF=$T/conf IDLE_CHECK=true
cat > "$NAS_SYNC_CONF" <<EOF
NAS_HOST=-
NC_SOURCE=$SRC
NC_TARGET=$DST
NC_EXTENSIONS="ngc nc tap"
EOF

fails=0
ok() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
sync() { "$HERE/../bin/nc-sync" >/dev/null; }

mkdir -p "$SRC/part a/sub" "$SRC/@eaDir/x" "$SRC/only_bak" "$SRC/#recycle" \
    "$SRC/\$RECYCLE.BIN/S-1-5-21" "$SRC/System Volume Information"
echo "G0 X1" > "$SRC/one.ngc"
echo "G0 X2" > "$SRC/part a/sub/two.NGC"
echo "G0 X3" > "$SRC/three.Tap"
echo "G0 X4" > "$SRC/four.nc"
echo x > "$SRC/one.ngc.bak"
echo x > "$SRC/only_bak/alt.bak"
echo x > "$SRC/model.stl"
echo x > "$SRC/one.ngc@synoeastream"
echo x > "$SRC/@eaDir/x/one.ngc"
echo x > "$SRC/#recycle/gone.ngc"
echo x > "$SRC/.DS_Store"
echo x > "$SRC/._one.ngc"
echo x > "$SRC/\$RECYCLE.BIN/S-1-5-21/\$R1.ngc"
echo x > "$SRC/System Volume Information/x.ngc"
echo x > "$SRC/~\$one.ngc"
echo x > "$SRC/~WRL0001.ngc"
echo x > "$SRC/Thumbs.db"
echo x > "$SRC/desktop.ini"
echo x > "$SRC/one.ngc:Zone.Identifier"
echo x > "$SRC/download.ngc.crdownload"

sync
ok "NC files fetched (subdirectories, spaces, upper case)" \
   '[ -f "$DST/one.ngc" ] && [ -f "$DST/part a/sub/two.NGC" ] && [ -f "$DST/three.Tap" ] && [ -f "$DST/four.nc" ]'
ok "other extensions, NAS/macOS/Windows metadata and temp files skipped" \
   '[ "$(find "$DST" -type f | wc -l)" = 4 ]'
ok "empty and excluded directories skipped" \
   '[ ! -e "$DST/only_bak" ] && [ ! -e "$DST/@eaDir" ] && [ ! -e "$DST/\$RECYCLE.BIN" ]'

ino=$(stat -c %i "$DST/one.ngc")
echo "G0 X1 Y1" > "$SRC/one.ngc"
touch -d '+1 min' "$SRC/one.ngc"
sync
ok "modified file updated" 'grep -q Y1 "$DST/one.ngc"'
ok "replaced atomically (new inode)" '[ "$(stat -c %i "$DST/one.ngc")" != "$ino" ]'

echo local > "$DST/note.txt"
echo local > "$DST/local.ngc"
rm "$SRC/four.nc"
sync
ok "file deleted on NAS deleted locally" '[ ! -e "$DST/four.nc" ]'
ok "local NC file without NAS counterpart deleted" '[ ! -e "$DST/local.ngc" ]'
ok "local non-NC file kept" '[ -f "$DST/note.txt" ]'

echo "G0 X5" > "$SRC/five.ngc"
IDLE_CHECK=false sync
ok "no sync while LinuxCNC is busy" '[ ! -e "$DST/five.ngc" ]'

exec 8>"$T/linuxcnc-nas-sync.nc-sync.lock"; flock 8
sync
ok "no sync while another run holds the lock" '[ ! -e "$DST/five.ngc" ]'
exec 8>&-
sync
ok "sync again afterwards" '[ -f "$DST/five.ngc" ]'

echo "G0 X6" > "$SRC/six.ngc"
ok "failing state check is an error, not a silent skip" \
   '! IDLE_CHECK=/nonexistent "$HERE/../bin/nc-sync" >/dev/null 2>&1 && [ ! -e "$DST/six.ngc" ]'

sed -i 's/^NC_EXTENSIONS=.*/NC_EXTENSIONS=".ngc,.NC"/' "$NAS_SYNC_CONF"
echo "G0 X7" > "$SRC/seven.nc"
echo "G0 X8" > "$SRC/eight.tap"
sync
ok "extensions with dots and commas accepted" \
   '[ -f "$DST/six.ngc" ] && [ -f "$DST/seven.nc" ] && [ ! -e "$DST/eight.tap" ]'

echo "NC_TARGET=$HOME" >> "$NAS_SYNC_CONF"
ok "home directory refused as NC_TARGET" '! "$HERE/../bin/nc-sync" -n >/dev/null 2>&1'

[ "$fails" = 0 ] && echo "All tests passed" || echo "$fails test(s) failed"
exit $((fails > 0))
