---
name: Bug report
about: Something does not work as described
labels: bug
---

**What happened, what did you expect?**


**Setup**
- LinuxCNC version (`dpkg -l linuxcnc-uspace`):
- Distribution and kernel (`uname -r`):
- Server: Synology (DSM version) / other NAS / Linux server with plain SSH / rrsync
- linuxcnc-nas-sync version (`git -C ~/linuxcnc-nas-sync log -1 --oneline`):

**Log** (`journalctl --user -u 'linuxcnc-*' --since today`), remove IP addresses and names if you like:

```
```

**Config** (`~/.config/linuxcnc-nas-sync/nas-sync.conf`, without private values):

```
```
