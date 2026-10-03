#!/bin/bash
# Measure real-time latency while nc-sync transfers files.
# Starts a headless HAL session (threads + timedelta), then runs several phases:
#   idle          no load
#   sync          full nc-sync in a loop, with the same limits as the systemd service
#   sync-nolimit  same, but without bandwidth limit
#   sync-raw      without bandwidth limit, nice, idle scheduling and CPU affinity
# Each sync run goes to a temporary target, so every run transfers all files.
# LinuxCNC must not be running. Needs a working nas-sync.conf.
#
# Usage: tests/latency-under-sync.sh [seconds per phase, default 90]
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
DUR=${1:-90}
BASE_NS=25000 SERVO_NS=1000000
CONF=${NAS_SYNC_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/linuxcnc-nas-sync/nas-sync.conf}
TMP=$(mktemp -d)
UNIT=lcnc-latency-load

pgrep -x rtapi_app >/dev/null && { echo "rtapi_app is running, stop LinuxCNC first." >&2; exit 1; }
[ -r "$CONF" ] || { echo "config missing: $CONF" >&2; exit 1; }

cleanup() {
    systemctl --user stop "$UNIT" 2>/dev/null || true
    halrun -U >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

n=$(nproc)
affinity=0-$((n > 1 ? n - 2 : 0))

halrun -U >/dev/null 2>&1 || true
halcmd loadrt threads name1=base period1=$BASE_NS name2=servo period2=$SERVO_NS
halcmd loadrt timedelta count=2
halcmd addf timedelta.0 servo
halcmd addf timedelta.1 base
halcmd start 2>/dev/null
sleep 5

measure() {
    local name=$1
    for i in 0 1; do halcmd setp timedelta.$i.reset 1; done
    sleep 0.1
    for i in 0 1; do halcmd setp timedelta.$i.reset 0; done
    sleep "$DUR"
    local smax smin bmax bmin
    smax=$(halcmd getp timedelta.0.max) smin=$(halcmd getp timedelta.0.min)
    bmax=$(halcmd getp timedelta.1.max) bmin=$(halcmd getp timedelta.1.min)
    worst() { local a=$(($1 - $3)) b=$(($3 - $2)); echo $((a > b ? a : b)); }
    printf '%-14s servo %6d ns   base %6d ns\n' "$name" \
        "$(worst "$smax" "$smin" $SERVO_NS)" "$(worst "$bmax" "$bmin" $BASE_NS)"
}

# $1 = bandwidth limit, remaining args = extra systemd-run properties
start_load() {
    local bw=$1; shift
    { cat "$CONF"; echo "NC_TARGET=$TMP/nc"; echo "BWLIMIT=$bw"; } > "$TMP/conf"
    systemd-run --user --quiet --unit="$UNIT" --collect "$@" \
        --setenv=NAS_SYNC_CONF="$TMP/conf" --setenv=XDG_RUNTIME_DIR="$TMP" \
        bash -c "while :; do rm -rf '$TMP/nc'; '$HERE/../bin/nc-sync' -f >/dev/null; done"
    sleep 3
}
stop_load() { systemctl --user stop "$UNIT"; sleep 2; }

LIMITS=(-p Nice=19 -p CPUSchedulingPolicy=idle -p IOSchedulingClass=idle -p CPUAffinity="$affinity")
bw=$(. "$CONF"; echo "${BWLIMIT:-0}")

echo "worst deviation from the thread period, $DUR s per phase ($(uname -r))"
measure idle
start_load "$bw" "${LIMITS[@]}"; measure sync; stop_load
start_load 0 "${LIMITS[@]}"; measure sync-nolimit; stop_load
start_load 0; measure sync-raw; stop_load
measure idle
