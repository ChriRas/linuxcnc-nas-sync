# Contributing

Bug reports and pull requests are welcome. Please open an issue first for larger changes.

## Layout

```
bin/nc-sync               entry point: NAS -> NC_TARGET
bin/config-backup         entry point: BACKUP_SOURCE -> snapshots on the NAS
lib/common.sh             shared helpers: config loading, lock, idle check, route check,
                          rsync wrapper, COMMON_EXCLUDES
lib/lcnc-idle.py          LinuxCNC state check, exit code contract:
                          0 free (stdout: loaded file), 1 busy, 2 unknown
systemd/                  unit templates; install.sh fills in @PREFIX@ and @AFFINITY@
install.sh                installs packages, config, key and units (idempotent)
etc/nas-sync.conf.example documented example config
tests/                    see below
```

## Tests

| Test | Where it can run |
|---|---|
| `tests/nc-sync-test.sh` | anywhere; needs only bash, rsync, util-linux. Uses a temp dir as fake NAS. |
| `tests/config-backup-test.sh` | anywhere, same as above |
| `tests/sim-states.py` | only with a running LinuxCNC **simulation** config (`linuxcnc <sim>.ini`). It switches the machine on and runs programs and MDI moves. Never on a real machine. |
| `tests/latency-under-sync.sh [seconds]` | on a real-time machine with a working config and NAS; LinuxCNC must be stopped. Measures latency with `halrun` while syncing. |

CI (`.github/workflows/ci.yml`) runs shellcheck, a Python syntax check and the two offline tests on every push and pull request. Run them locally before pushing:

```sh
shellcheck -x -S warning bin/nc-sync bin/config-backup lib/common.sh install.sh tests/*.sh
tests/nc-sync-test.sh && tests/config-backup-test.sh
```

### Test hooks

The scripts can run without NAS and LinuxCNC:

| Hook | Effect |
|---|---|
| `NAS_SYNC_CONF=<file>` | use this config instead of `~/.config/linuxcnc-nas-sync/nas-sync.conf` |
| `NAS_HOST=-` (in the config) | `NC_SOURCE` and `BACKUP_TARGET` are local paths: a directory acts as the NAS |
| `IDLE_CHECK=<command>` | replaces `lib/lcnc-idle.py`, e.g. `true` (free) or `false` (busy) |
| `XDG_RUNTIME_DIR=<dir>` | location of the lock files, keeps tests apart from a running installation |
| option `-f` | skip the LinuxCNC state check |

New behaviour needs a case in the matching `tests/*-test.sh`, using the existing `ok "description" 'condition'` pattern.

## Design rules

- **Real-time first.** Everything runs with low CPU and I/O priority, away from the real-time CPU, and never sends traffic over `FORBIDDEN_IF`. Don't add work that runs while LinuxCNC executes a program.
- **Nothing but rsync on the server.** No remote shell commands, so it works with Synology non-admin users and with `rrsync`. Listing and deleting are done with rsync, too. Option paths must not contain `..` (rrsync rejects them).
- **Safe by default.** Skip quietly while LinuxCNC is busy or its state is unknown; fail loudly (non-zero exit, message on stderr) on anything else, so it shows up in the journal.
- **No private data in the repo.** Examples use `nas.example.lan`, `192.0.2.x` or `192.168.1.x`.

## Conventions

- Bash with `set -euo pipefail`; build rsync arguments in arrays; quote variables.
- Python 3, standard library only (plus the `linuxcnc` module).
- Code comments, program output and commit messages in English.
- Commit messages: imperative subject line (`Add …`, `Fix …`), body explains why.
