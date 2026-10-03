#!/usr/bin/env python3
"""Drive a running LinuxCNC simulation through all relevant states and check
lib/lcnc-idle.py. Use with a simulation config only, never on a real machine.

Usage: start linuxcnc <sim>.ini, then run tests/sim-states.py
"""
import os
import subprocess
import sys
import tempfile
import time

import linuxcnc

HERE = os.path.dirname(os.path.abspath(__file__))
IDLE = os.path.join(HERE, "..", "lib", "lcnc-idle.py")

s = linuxcnc.stat()
c = linuxcnc.command()
fails = 0


def wait(cond, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        s.poll()
        if cond():
            return True
        time.sleep(0.1)
    return False


def check(name, expected, expect_file=None):
    global fails
    r = subprocess.run([IDLE], capture_output=True, text=True)
    ok = r.returncode == expected
    if expect_file is not None:
        ok = ok and r.stdout.strip() == expect_file
    fails += not ok
    print(f"{'OK  ' if ok else 'FAIL'} {name}: exit={r.returncode} "
          f"({r.stderr.strip()}) file={r.stdout.strip()!r}")


def settled(timeout=10):
    return wait(lambda: s.interp_state == linuxcnc.INTERP_IDLE and s.queue == 0
                and s.state != linuxcnc.RCS_EXEC, timeout)


def mode(m):
    c.mode(m)
    c.wait_complete()
    wait(lambda: s.task_mode == m)


prog = os.path.join(tempfile.mkdtemp(), "slow.ngc")
with open(prog, "w") as f:
    f.write("G21 G90\nG0 X0 Y0 Z0\n")
    for _ in range(20):
        f.write("G1 X20 F200\nG1 X0\n")
    f.write("M2\n")

c.state(linuxcnc.STATE_ESTOP_RESET)
c.state(linuxcnc.STATE_ON)
wait(lambda: s.task_state == linuxcnc.STATE_ON)
mode(linuxcnc.MODE_MANUAL)
# The sim config does not require homing (NO_FORCE_HOMING = 1)

check("machine on, idle", 0)

mode(linuxcnc.MODE_AUTO)
c.program_open(prog)
c.wait_complete()
wait(lambda: s.file == prog)
check("program loaded, not started", 0, expect_file=prog)

c.auto(linuxcnc.AUTO_RUN, 0)
wait(lambda: s.interp_state != linuxcnc.INTERP_IDLE)
time.sleep(0.5)
check("program running", 1)

c.auto(linuxcnc.AUTO_PAUSE)
wait(lambda: s.interp_state == linuxcnc.INTERP_PAUSED)
check("program paused", 1)

c.abort()
wait(lambda: s.interp_state == linuxcnc.INTERP_IDLE)
settled()
check("after abort", 0, expect_file=prog)

mode(linuxcnc.MODE_MDI)
c.mdi("G1 X30 F100")
wait(lambda: s.interp_state != linuxcnc.INTERP_IDLE or s.queue > 0)
time.sleep(0.3)
check("MDI move running", 1)
settled(30)
check("MDI finished", 0)

c.state(linuxcnc.STATE_ESTOP)
wait(lambda: s.task_state == linuxcnc.STATE_ESTOP)
settled()
check("E-stop", 0)

os.remove(prog)
print("All tests passed" if not fails else f"{fails} test(s) failed")
sys.exit(1 if fails else 0)
