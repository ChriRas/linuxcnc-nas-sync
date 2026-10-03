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

mkdir -p "$SRC/part a/sub" "$SRC/@eaDir/x" "$SRC/only_bak" "$SRC/#recycle"
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

sync
ok "NC files fetched (subdirectories, spaces, upper case)" \
   '[ -f "$DST/one.ngc" ] && [ -f "$DST/part a/sub/two.NGC" ] && [ -f "$DST/three.Tap" ] && [ -f "$DST/four.nc" ]'
ok "other extensions and Synology/macOS metadata skipped" \
   '[ "$(find "$DST" -type f | wc -l)" = 4 ]'
ok "empty directories skipped" '[ ! -e "$DST/only_bak" ] && [ ! -e "$DST/@eaDir" ]'

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

[ "$fails" = 0 ] && echo "All tests passed" || echo "$fails test(s) failed"
exit $((fails > 0))
