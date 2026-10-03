# linuxcnc-nas-sync

Fetches NC programs from a NAS onto a LinuxCNC machine and backs up the LinuxCNC configuration to the NAS.

- Sync NAS → machine (`rsync` over SSH, no permanent mount), only while no program is running.
- Config backup machine → NAS as snapshots (`rsync --link-dest`), configurable retention.
- Runs from systemd timers with low CPU and I/O priority, safe on a real-time kernel.

Status: work in progress.

## License

MIT, see [LICENSE](LICENSE).
