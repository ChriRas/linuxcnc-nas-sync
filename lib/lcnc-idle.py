#!/usr/bin/env python3
"""Check whether LinuxCNC is currently executing a program.

Exit codes:
  0  free: LinuxCNC is not running, or the interpreter is idle
  1  busy: program running or paused, MDI active, command executing
  2  unknown: status not readable (e.g. LinuxCNC is starting up)

On exit 0, stdout contains the path of the loaded file (empty if none).
The reason is written to stderr.
"""
import os
import sys
import time

FREE, BUSY, UNKNOWN = 0, 1, 2
LOCKFILE = "/tmp/linuxcnc.lock"
STALE_AFTER = 300  # seconds; an older lock without linuxcncsvr is a crash leftover


def lcnc_running():
    """LinuxCNC is running if the NML server process exists."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() == "linuxcncsvr":
                    return True
        except OSError:
            pass
    return False


def main():
    if not lcnc_running():
        try:
            age = time.time() - os.path.getmtime(LOCKFILE)
        except OSError:
            age = None
        if age is not None and age < STALE_AFTER:
            # LinuxCNC is starting up: do not interfere.
            print("lock file present but no linuxcncsvr (starting up?)", file=sys.stderr)
            return UNKNOWN
        if age is not None:
            print(f"stale lock file ({age:.0f} s old), LinuxCNC not running", file=sys.stderr)
            print("")
            return FREE
        print("LinuxCNC not running", file=sys.stderr)
        print("")
        return FREE

    try:
        import linuxcnc
        s = linuxcnc.stat()
        s.poll()
    except Exception as e:  # linuxcnc.error, ImportError
        print(f"status not readable: {e}", file=sys.stderr)
        return UNKNOWN

    if s.interp_state != linuxcnc.INTERP_IDLE:
        names = {linuxcnc.INTERP_READING: "running", linuxcnc.INTERP_PAUSED: "paused",
                 linuxcnc.INTERP_WAITING: "waiting"}
        print(f"interpreter {names.get(s.interp_state, s.interp_state)}", file=sys.stderr)
        return BUSY
    if s.state == linuxcnc.RCS_EXEC:
        print("command executing", file=sys.stderr)
        return BUSY
    if s.queue > 0:
        print("motion queue not empty", file=sys.stderr)
        return BUSY

    print("idle", file=sys.stderr)
    print(s.file or "")
    return FREE


if __name__ == "__main__":
    sys.exit(main())
