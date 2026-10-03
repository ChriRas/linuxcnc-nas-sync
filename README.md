# linuxcnc-nas-sync

Keeps the NC programs on a LinuxCNC machine in sync with a NAS and backs up the LinuxCNC configuration to the NAS.

- **nc-sync** (NAS → machine): fetches NC programs every minute, but only while LinuxCNC is not running a program.
- **config-backup** (machine → NAS): snapshots of the LinuxCNC configuration, created only when something changed, kept for a configurable time.
- No permanent network mount. Everything runs as `rsync` over SSH with a dedicated key.
- Built for real-time kernels: low CPU and I/O priority, kept away from the CPU that runs the LinuxCNC real-time thread.

Works with a Synology NAS or any other server that offers rsync over SSH (see [Other rsync servers](#other-rsync-servers)). Developed and tested with LinuxCNC 2.9.10 (uspace, PREEMPT_RT) on Debian 13, a Synology NAS running DSM 7.3 and a plain OpenSSH server with `rrsync`.

## How it works

### nc-sync

1. `lib/lcnc-idle.py` asks LinuxCNC for its state through the `linuxcnc` Python module:
   - LinuxCNC not running, or interpreter idle → sync allowed
   - program running or paused, MDI command active, motion queued → skip
   - state unknown (e.g. LinuxCNC is starting up) → skip
2. `rsync` copies files from `NC_SOURCE` on the NAS to `NC_TARGET` (default `~/linuxcnc/nc_files`):
   - only files with the extensions in `NC_EXTENSIONS` (case-insensitive), including subdirectories
   - metadata and temp files are ignored (see [Excluded files](#excluded-files)), as are all dot files
   - files deleted on the NAS are deleted on the machine
   - every file is written under a temporary name and then renamed, so LinuxCNC never sees a half-written file. A file that is loaded in LinuxCNC is replaced as well; reload it to get the new version.

> **Note:** `NC_TARGET` mirrors the NAS. An NC file saved only on the machine (e.g. from the GUI) is deleted on the next run. Files with other extensions in `NC_TARGET` are left alone.

### config-backup

- Copies `BACKUP_SOURCE` (default `~/linuxcnc/configs`) to a new snapshot directory `BACKUP_TARGET/YYYY-MM-DD_HHMMSS/`.
- A new snapshot is only created if something changed since the last one. Unchanged files are hard links to the previous snapshot (`rsync --link-dest`), so a snapshot costs only the space of the changed files.
- A snapshot counts as complete only once its marker file `YYYY-MM-DD_HHMMSS.complete` exists. Incomplete snapshots (aborted runs) are deleted on the next run.
- Snapshots older than `BACKUP_KEEP_DAYS` are deleted, but the newest `BACKUP_KEEP_MIN` snapshots are always kept.
- Skipped: the [excluded files](#excluded-files) plus `__pycache__`, `*.pyc`, `*.pickle*`, `*-shm`, `*.log`. Regular dot files (e.g. `.halshow_watchlist_backup`) are kept. Included on purpose: `linuxcnc.var` (offsets), tool tables, `tool_table.db`.
- Needs only rsync on the NAS, no shell. This matters on Synology, where non-admin users get no SSH shell.

### Excluded files

Never transferred in either direction (defined in `lib/common.sh`, `COMMON_EXCLUDES`):

| Source | Patterns |
|---|---|
| Synology / NAS | `@eaDir/`, `#recycle/`, `#snapshot/`, `*@synoeastream`, `.smbdelete*` |
| macOS | `.DS_Store`, `._*`, `.Spotlight-V100/`, `.Trashes/` |
| Windows | `$RECYCLE.BIN/`, `System Volume Information/`, `Thumbs.db`, `ehthumbs*.db`, `desktop.ini`, `~*` (Office owner files `~$name`, `~WRL0001.tmp`), `*.tmp`, `*:Zone.Identifier` |
| Downloads, editors | `*.crdownload`, `*.part`, `*.partial`, `*~`, `.~lock.*#` (LibreOffice) |

`nc-sync` only transfers NC extensions anyway. The list matters for files that would otherwise slip through, e.g. `~$part.ngc` or `$RECYCLE.BIN/…/$R1.ngc`.

### Scheduling

systemd user units, installed by `install.sh`:

| Unit | When |
|---|---|
| `linuxcnc-nc-sync.timer` | every minute |
| `linuxcnc-config-backup.timer` | hourly |
| `linuxcnc-config-backup.path` | when `/tmp/linuxcnc.lock` changes, i.e. after LinuxCNC exits |

Both services run with `Nice=19`, `CPUSchedulingPolicy=idle`, `IOSchedulingClass=idle` and `CPUAffinity` set to all CPUs except the last one. Without `isolcpus`, LinuxCNC (uspace) runs its real-time threads on the highest-numbered CPU. Lingering is enabled, so the timers run from boot without a login. Runs without changes are not logged.

## Requirements

- LinuxCNC 2.9 (uspace) with the `linuxcnc` Python module
- `rsync`, `openssh-client`, `python3` (installed by `install.sh` if missing)
- A server reachable via SSH that can run rsync: a Synology NAS ([setup](#1-nas-synology-dsm-7)) or any other server ([requirements](#other-rsync-servers))

## Setup

### 1. NAS (Synology DSM 7)

1. **Control Panel → Shared Folder:** create a shared folder for the backups, e.g. `Backup_LinuxCNC`.
2. **Control Panel → User & Group → Create:** create a dedicated user, e.g. `cnc-sync`, with a long random password.
   - Permissions: *read only* on the share with the NC programs, *read/write* on the backup share, *no access* to everything else.
   - Applications: allow *rsync* only.
3. **User & Group → Advanced:** enable the user home service. The SSH key goes into the user's home.
4. **Control Panel → File Services → rsync:** enable the rsync service (rsync over SSH).

Paths on Synology are absolute, e.g. `/volume1/CNC/nc_programs`.

### Other rsync servers

Any server works (Linux box, other NAS brands, TrueNAS, a Raspberry Pi with a USB disk) if it meets these requirements:

| Requirement | Why |
|---|---|
| SSH server reachable from the machine, key authentication enabled | All transfers run as `rsync` over SSH with `BatchMode=yes`; password prompts are impossible. |
| `rsync` installed on the server (3.1 or newer recommended) | The client starts `rsync --server` on the server via SSH. An rsync daemon (`rsync://`, port 873) is **not** used. |
| A user whose login shell can run commands (not `/usr/sbin/nologin`, `/bin/false`), or a forced command such as `rrsync` | sshd starts the remote rsync through the user's shell or the forced command. |
| Read access to `NC_SOURCE` | NC sync only reads from the server. |
| Write access to `BACKUP_TARGET`, including deleting | Snapshots are created there and old ones deleted. |
| Filesystem of `BACKUP_TARGET` supports hard links (ext4, XFS, Btrfs, ZFS; **not** FAT32/exFAT) | Unchanged files are hard links to the previous snapshot. Without hard link support the snapshots do not work as intended. |
| Host key in `~/.ssh/known_hosts` on the machine | `BatchMode` refuses unknown hosts. Add it once with `ssh-keyscan` and compare the fingerprint. |
| Route to the server not via the real-time NIC | Set `FORBIDDEN_IF`; runs abort otherwise. |

No shell commands besides rsync are executed on the server: listing, transferring and deleting old snapshots are all done with rsync. Paths in the config are absolute server paths, or relative to the user's home directory.

Non-standard port or other SSH options: add a host entry to `~/.ssh/config` on the machine and use its name as `NAS_HOST`:

```
Host backupserver
    HostName 192.0.2.10
    Port 2222
```

#### Recommended: restrict the key with rrsync

`rrsync` ships with rsync (Debian: `/usr/bin/rrsync`) and limits an SSH key to rsync inside one directory. Put the NC programs and the backups below a common directory, e.g. `/srv/cnc/nc` and `/srv/cnc/backup`, and prefix the key in the server user's `~/.ssh/authorized_keys`:

```
command="rrsync -no-lock /srv/cnc",restrict ssh-ed25519 AAAA... linuxcnc-nas-sync@machine
```

Then write the paths in `nas-sync.conf` **relative to that directory, with a leading slash**:

```sh
NC_SOURCE=/nc
BACKUP_TARGET=/backup
```

- `-no-lock` is required: without it rrsync allows only one rsync per user at a time, so a backup and a sync starting together would fail.
- Do not use `-absolute`: it applies only to transfer paths, not to `--link-dest`, so the hard-link step of the backup would point to the wrong place.
- `-ro` (read-only) does not work for a shared key, because the backup needs to write.

### 2. Machine

```sh
git clone https://github.com/ChriRas/linuxcnc-nas-sync.git ~/linuxcnc-nas-sync
cd ~/linuxcnc-nas-sync
./install.sh
```

`install.sh` is idempotent. It installs missing packages, creates `~/.config/linuxcnc-nas-sync/nas-sync.conf` from the example, creates the SSH key `~/.ssh/linuxcnc-nas-sync`, installs and enables the systemd user units and enables lingering. Run it as the user that runs LinuxCNC, not as root.

### 3. SSH key on the NAS

DSM gives non-admin users no shell, so `ssh-copy-id` does not work. Instead:

1. In File Station (as admin), open `homes/<user>`, create a folder `.ssh` and upload a file `authorized_keys` containing the line from `~/.ssh/linuxcnc-nas-sync.pub`.
2. Fix the permissions once as an admin via SSH. `sshd` ignores the key if the home directory is group-writable:

   ```sh
   ssh -t <admin>@<nas> 'sudo sh -c "cd /var/services/homes/<user> && chown -R <user>:users .ssh && chmod 755 . && chmod 700 .ssh && chmod 600 .ssh/authorized_keys"'
   ```

3. Accept the host key and test:

   ```sh
   ssh-keyscan -t ed25519 <nas> >> ~/.ssh/known_hosts
   rsync -e "ssh -i ~/.ssh/linuxcnc-nas-sync" --list-only <user>@<nas>:/volume1/
   ```

### 4. Configuration

Edit `~/.config/linuxcnc-nas-sync/nas-sync.conf`. The options are explained in [`etc/nas-sync.conf.example`](etc/nas-sync.conf.example). Set `FORBIDDEN_IF` to the interface of the real-time hardware (e.g. the NIC of a Mesa Ethernet card): the scripts abort if the route to the NAS would use it.

Then do a dry run:

```sh
bin/nc-sync -n
```

## Usage

```sh
systemctl --user list-timers 'linuxcnc-*'     # next runs
journalctl --user -u 'linuxcnc-*' -f          # log (changes and errors only)
bin/nc-sync -n                                # dry run: show what would change
bin/nc-sync                                   # sync now (skips if LinuxCNC is busy)
bin/config-backup                             # backup now (only if something changed)
./install.sh -u                               # remove the units
```

### Restore a config snapshot

Each snapshot is a complete copy of the configuration directory. Copy it back with LinuxCNC stopped:

```sh
rsync -e "ssh -i ~/.ssh/linuxcnc-nas-sync" -av \
    <user>@<nas>:/volume1/Backup_LinuxCNC/2026-10-03_024546/ ~/linuxcnc/configs/
```

Snapshots can also be copied from the NAS share directly (SMB, File Station).

## Tests

```sh
tests/nc-sync-test.sh             # nc-sync against a local fake NAS
tests/config-backup-test.sh       # config-backup against a local fake NAS
tests/sim-states.py               # idle check, needs a running LinuxCNC *simulation*
tests/latency-under-sync.sh 120   # real-time latency with and without sync load
```

`tests/sim-states.py` drives the machine (machine on, program run, MDI moves). Use it with a simulation config only, never on a real machine.

## License

MIT, see [LICENSE](LICENSE).
