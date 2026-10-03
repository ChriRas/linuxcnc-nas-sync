# linuxcnc-nas-sync

[![CI](https://github.com/ChriRas/linuxcnc-nas-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/ChriRas/linuxcnc-nas-sync/actions/workflows/ci.yml)

Keeps the NC programs on a LinuxCNC machine in sync with a NAS and backs up the LinuxCNC configuration to the NAS.

- **nc-sync** (NAS → machine): fetches NC programs every minute, but only while LinuxCNC is not running a program.
- **config-backup** (machine → NAS): snapshots of the LinuxCNC configuration, created only when something changed, kept for a configurable time.
- No permanent network mount. Everything runs as `rsync` over SSH with a dedicated key.
- Built for real-time kernels: low CPU and I/O priority, kept away from the CPU that runs the LinuxCNC real-time thread.

Works with a Synology NAS or any other server that offers rsync over SSH (see [Other rsync servers](#other-rsync-servers-advanced)). Developed and tested with LinuxCNC 2.9.10 (uspace, PREEMPT_RT) on Debian 13, a Synology NAS running DSM 7.3 and a plain OpenSSH server with `rrsync`.

**Contents:** [How it works](#how-it-works) · [Setup](#setup) · [Usage](#usage) · [Troubleshooting](#troubleshooting) · [Restore a backup](#restore-a-config-snapshot) · [Update, move, uninstall](#update-move-uninstall) · [Other rsync servers](#other-rsync-servers-advanced) · [Contributing](CONTRIBUTING.md)

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

> [!WARNING]
> `NC_TARGET` mirrors the NAS. Every NC file in `NC_TARGET` (and its subfolders) that does not exist on the NAS is **deleted**, including programs saved only on the machine. Files with other extensions are left alone. See [step 7](#7-first-sync-check-what-would-be-deleted) before the first run.

### config-backup

- Copies `BACKUP_SOURCE` (default `~/linuxcnc/configs`) to a new snapshot directory `BACKUP_TARGET/YYYY-MM-DD_HHMMSS/`. Snapshot names are in UTC.
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
- `git` to download the project, plus `rsync`, `openssh-client`, `python3` (installed by `install.sh` if missing)
- A server reachable via SSH that can run rsync: a Synology NAS (setup below) or [any other server](#other-rsync-servers-advanced)

## Setup

You don't need to understand the scheduling details. `install.sh` sets them up. Follow the steps in order. Each step says **where** to do it:

- **[DSM]**: the Synology web interface in your browser
- **[Machine]**: a terminal on the LinuxCNC computer

### Values you need

The examples below use these values. Replace them with your own everywhere.

| Example | What it is | How to find it |
|---|---|---|
| `192.168.1.20` | IP address of the NAS | DSM → *Control Panel → Network → Network Interface*, or your router's device list. Use a fixed IP (DHCP reservation in the router); names like `nas.local` often don't resolve on the machine. |
| `CNC` | Shared folder on the NAS with your NC programs | DSM → *Control Panel → Shared Folder* |
| `/volume1/CNC/nc_programs` | Path of the NC programs as the NAS sees it | `/volume1` (or `/volume2` …, see the *Location* column in *Shared Folder*) + `/` + share name + subfolder. Case-sensitive. |
| `Backup_LinuxCNC` | Shared folder for the backups | You create it in step 1. |
| `cnc-sync` | NAS user for the machine | You create it in step 1. |
| `youradmin` | Your DSM administrator account | The account you log in to DSM with. It must be in the *administrators* group. |

### 1. Prepare the NAS [DSM]

1. *Control Panel → Shared Folder*: if you don't have a share for NC programs yet, create one (e.g. `CNC`) and put your programs into a subfolder (e.g. `nc_programs`). Create a second shared folder for the backups, e.g. `Backup_LinuxCNC`.
2. *Control Panel → User & Group → Create*: create a user `cnc-sync` with a long random password (you never need to type it again).
   - Permissions: *Read only* on `CNC`, *Read/Write* on `Backup_LinuxCNC`, *No access* to everything else.
   - Applications: allow *rsync* only.
3. *User & Group → Advanced*: enable the *user home service*. The machine's key will be stored in the home folder of `cnc-sync`.
4. *Control Panel → File Services → rsync*: enable the *rsync service*.
5. *Control Panel → Terminal & SNMP*: enable the *SSH service* (port 22). **Keep it enabled**, the sync runs over SSH.

### 2. Install on the machine [Machine]

```sh
sudo apt install git          # if git is missing
git clone https://github.com/ChriRas/linuxcnc-nas-sync.git ~/linuxcnc-nas-sync
cd ~/linuxcnc-nas-sync
./install.sh
```

Run it as the user that runs LinuxCNC, not as root. It may ask for your password (`sudo`) to install missing packages. On the first run it:

- creates the config file `~/.config/linuxcnc-nas-sync/nas-sync.conf`,
- creates an SSH key `~/.ssh/linuxcnc-nas-sync` and prints its public part (one line starting with `ssh-ed25519`),
- installs the scheduled jobs but does **not** start them yet.

Keep the folder `~/linuxcnc-nas-sync` where it is; the scheduled jobs run the scripts from there.

### 3. Put the key on the NAS [Machine]

The NAS must accept the machine's key for the user `cnc-sync`. DSM gives normal users no shell, so `ssh-copy-id` does not work. Instead, run this on the machine. It logs in as your DSM admin, stores the key in the home folder of `cnc-sync` and sets the permissions SSH insists on:

```sh
KEY=$(cat ~/.ssh/linuxcnc-nas-sync.pub)
ssh -t youradmin@192.168.1.20 "sudo sh -c 'cd /var/services/homes/cnc-sync && mkdir -p .ssh && echo \"$KEY\" > .ssh/authorized_keys && chown -R cnc-sync:users .ssh && chmod 755 . && chmod 700 .ssh && chmod 600 .ssh/authorized_keys'"
```

- You are asked for the admin password twice: once for SSH, once for `sudo`.
- If asked *"Are you sure you want to continue connecting"*, type `yes`.
- `cd: can't cd to /var/services/homes/cnc-sync` means the user home service (step 1.3) is off or the user name is wrong.
- This replaces any existing `authorized_keys` of `cnc-sync`. That is fine for a user dedicated to the machine.

<details>
<summary>Alternative without admin SSH: File Station</summary>

1. On the machine, show the key: `cat ~/.ssh/linuxcnc-nas-sync.pub`
2. Copy that **single line** into a plain-text file named exactly `authorized_keys` (no `.txt`; on Windows enable *show file extensions*). It must stay one line.
3. In File Station (as admin), open `homes/cnc-sync`, create a folder `.ssh` and upload the file into it.
4. SSH still ignores the key if the home folder permissions are too open. Fixing that needs one admin SSH command anyway:
   `ssh -t youradmin@192.168.1.20 'sudo sh -c "cd /var/services/homes/cnc-sync && chown -R cnc-sync:users .ssh && chmod 755 . && chmod 700 .ssh && chmod 600 .ssh/authorized_keys"'`

</details>

### 4. Trust the NAS host key [Machine]

The scheduled jobs refuse unknown servers. Store the NAS host key once. Use **exactly** the value you will put into `NAS_HOST` (here the IP):

```sh
ssh-keyscan -t ed25519 192.168.1.20 >> ~/.ssh/known_hosts
ssh-keygen -lf ~/.ssh/known_hosts
```

Optional check that you really talk to your NAS: the fingerprint (`SHA256:…`) must match the one shown on the NAS by `ssh youradmin@192.168.1.20 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.

### 5. Test the connection [Machine]

```sh
rsync -e "ssh -i ~/.ssh/linuxcnc-nas-sync -o BatchMode=yes" --list-only cnc-sync@192.168.1.20:/volume1/CNC/nc_programs/
rsync -e "ssh -i ~/.ssh/linuxcnc-nas-sync -o BatchMode=yes" --list-only cnc-sync@192.168.1.20:/volume1/Backup_LinuxCNC/
```

Both must list folder contents **without asking for a password**. If they don't, see [Troubleshooting](#troubleshooting).

### 6. Edit the config [Machine]

```sh
nano ~/.config/linuxcnc-nas-sync/nas-sync.conf
```

Set at least `NAS_HOST`, `NAS_USER`, `NC_SOURCE` and `BACKUP_TARGET`. Each option is explained in the file ([`etc/nas-sync.conf.example`](etc/nas-sync.conf.example)). The file is a shell script: no spaces around `=`, quotes around values with spaces.

```sh
NAS_HOST=192.168.1.20
NAS_USER=cnc-sync
NC_SOURCE=/volume1/CNC/nc_programs
BACKUP_TARGET=/volume1/Backup_LinuxCNC
```

**`FORBIDDEN_IF`** protects the network connection to a Mesa Ethernet card (7i76E, 7i96 …): the scripts abort if traffic to the NAS would go through it.

- Run `ip -br addr`. The Mesa interface is the one with an address in the card's network (often `10.10.10.x`, see `board_ip` in your `.hal`/`.ini`). Names look like `enp3s0` or `eth1`.
- Put that name into `FORBIDDEN_IF`, e.g. `FORBIDDEN_IF=enp3s0`.
- Check: in `ip route get 192.168.1.20` the name after `dev` must be a **different** interface.
- No Ethernet Mesa card (parallel port, PCI card): leave it empty.

### 7. First sync: check what would be deleted [Machine]

> [!WARNING]
> Every `.ngc`/`.nc`/`.tap` file in `NC_TARGET` that is not on the NAS will be deleted. Copy programs that exist only on the machine to the NAS first, or make a copy: `cp -a ~/linuxcnc/nc_files ~/nc_files.bak`. Use a folder dedicated to the sync as `NC_TARGET`; the script refuses `/` and your home directory.

Dry run, changes nothing:

```sh
~/linuxcnc-nas-sync/bin/nc-sync -n
```

Each output line is one file. Lines starting with `>f` would be copied from the NAS, lines starting with `*deleting` would be deleted on the machine. No output means nothing to do.

### 8. Start the scheduled jobs [Machine]

```sh
cd ~/linuxcnc-nas-sync
./install.sh
```

Now the jobs run. To verify: put a file `test.ngc` into the NC folder on the NAS. Within about a minute it appears in `~/linuxcnc/nc_files`. Delete it on the NAS and it disappears on the machine.

## Usage

```sh
systemctl --user list-timers 'linuxcnc-*'           # when the jobs run next
journalctl --user -u 'linuxcnc-*' -f                # log: changes and errors only
systemctl --user status linuxcnc-nc-sync.service    # result of the last sync
~/linuxcnc-nas-sync/bin/nc-sync -n                  # dry run: show what would change
~/linuxcnc-nas-sync/bin/nc-sync                     # sync now (skips while LinuxCNC is busy)
~/linuxcnc-nas-sync/bin/config-backup               # backup now (only if something changed)
```

An empty log is normal: runs without changes are not logged.

## Troubleshooting

First look at the log: `journalctl --user -u 'linuxcnc-*' --since today`

| Message | Cause and fix |
|---|---|
| `Permission denied (publickey)` or a password prompt in step 5 | The NAS ignores the key. Repeat [step 3](#3-put-the-key-on-the-nas-machine). Check user name, home service (step 1.3) and that `authorized_keys` is one line. |
| `Host key verification failed` | Host key not stored, or stored under another name/IP than `NAS_HOST`. Repeat [step 4](#4-trust-the-nas-host-key-machine) with the exact `NAS_HOST` value. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | The NAS was reinstalled or replaced, or something is wrong in the network. If you know why: `ssh-keygen -R 192.168.1.20`, then repeat step 4. |
| `ERROR: route to … goes via …, aborting` | Traffic to the NAS would go through the Mesa interface. Check the IP address of the NAS and the network setup, see step 6. |
| `ERROR: cannot resolve …` | `NAS_HOST` is a name the machine cannot resolve. Use the IP address. |
| `change_dir … failed: No such file or directory` | Wrong path in `NC_SOURCE` or `BACKUP_TARGET` (check `/volume1`, case). |
| `ERROR: config missing` | Run `./install.sh` once, it creates the config. |
| `ERROR: LinuxCNC state check failed` | `lib/lcnc-idle.py` cannot run, e.g. `python3` missing. Run it by hand to see the error. |
| Nothing happens, no errors | The jobs only sync while LinuxCNC is idle. Check the state: `~/linuxcnc-nas-sync/lib/lcnc-idle.py; echo $?` (0 = free, 1 = busy, 2 = unknown). Check that the timers are listed in `systemctl --user list-timers`. |

Notes:

- If the Python module `linuxcnc` is missing, the state is *unknown* while LinuxCNC runs, and nothing is synced until LinuxCNC is closed.
- After a LinuxCNC crash, `/tmp/linuxcnc.lock` may stay behind. For the first 5 minutes it counts as "LinuxCNC is starting" and blocks the jobs; after that it is treated as a leftover.

## Restore a config snapshot

Each snapshot is a complete copy of the configuration directory, named by its UTC time.

1. **Close LinuxCNC.**
2. List the snapshots (or look in File Station):

   ```sh
   rsync -e "ssh -i ~/.ssh/linuxcnc-nas-sync" --list-only cnc-sync@192.168.1.20:/volume1/Backup_LinuxCNC/
   ```

3. Copy one back:

   ```sh
   rsync -e "ssh -i ~/.ssh/linuxcnc-nas-sync" -av \
       cnc-sync@192.168.1.20:/volume1/Backup_LinuxCNC/2026-10-03_024546/ ~/linuxcnc/configs/
   ```

This overwrites `linuxcnc.var` and the tool tables too: work offsets and tool data go back to the state of that snapshot. Files added after the snapshot are kept.

## Update, move, uninstall

**Update:**

```sh
cd ~/linuxcnc-nas-sync && git pull && ./install.sh
```

**Move the folder:** the scheduled jobs point to the folder's path. After moving it, run `./install.sh` in the new location.

**Uninstall:**

1. `~/linuxcnc-nas-sync/install.sh -u` stops and removes the scheduled jobs. Files in `NC_TARGET` and the backups on the NAS stay.
2. Optional: delete config and key: `rm -r ~/.config/linuxcnc-nas-sync ~/.ssh/linuxcnc-nas-sync ~/.ssh/linuxcnc-nas-sync.pub`
3. Optional: `loginctl disable-linger` (only if nothing else needs jobs to run without a login).
4. On the NAS: delete the user `cnc-sync` or its `.ssh` folder.
5. Delete the folder `~/linuxcnc-nas-sync`.

## Other rsync servers (advanced)

Synology users can skip this section. Any server works (Linux box, other NAS brands, TrueNAS, a Raspberry Pi with a USB disk) if it meets these requirements:

| Requirement | Why |
|---|---|
| SSH server reachable from the machine, key authentication enabled | All transfers run as `rsync` over SSH with `BatchMode=yes`; password prompts are impossible. |
| `rsync` installed on the server (3.1 or newer recommended) | The client starts `rsync --server` on the server via SSH. An rsync daemon (`rsync://`, port 873) is **not** used. |
| A user whose login shell can run commands (not `/usr/sbin/nologin`, `/bin/false`), or a forced command such as `rrsync` | sshd starts the remote rsync through the user's shell or the forced command. |
| Read access to `NC_SOURCE` | NC sync only reads from the server. |
| Write access to `BACKUP_TARGET`, including deleting. Its parent directory must exist. | Snapshots are created there and old ones deleted. `BACKUP_TARGET` itself is created on the first run. |
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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, tests and conventions.

## License

MIT, see [LICENSE](LICENSE).
