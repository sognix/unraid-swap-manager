# Swap Manager — Unraid swap plugin

<img src="icon.png" alt="Swap Manager icon" width="96" align="right">

Unraid plugin: create and manage a swapfile (or a ZFS zvol) from the WebUI - size,
location, autostart, enable/disable - plus a swap usage history graph on the settings page
and a dashboard tile. Swap follows the array lifecycle automatically: it is enabled after
the array start and disabled before the array stop, so a swapfile on a pool never blocks
unmounting.

Target: Unraid 6.12+, tested against 7.x.

## Install

- **Apps (Community Applications):** search for "Swap Manager" and install.
- **Manually:** Plugins → Install Plugin → paste
  `https://raw.githubusercontent.com/sognix/unraid-swap-manager/main/swap-manager.plg`

## Support

Questions, bugs and feature requests: [GitHub issues](https://github.com/sognix/unraid-swap-manager/issues).

## Usage

Settings → User Utilities → Swap Manager: set size/path/filesystem, "Create swapfile", then
"Enable" (the buttons are at the end of Swap Settings). A swap usage history graph (5 minutes / 1 hour / 24 hours,
kept in RAM) is configured under History Settings: on/off, sampling interval (seconds,
minimum 5, default 30) and the range the graph shows, with their own Default/Save buttons.
With the history on, the dashboard tile shows the same graph instead of the usage ring.

Changing the size: Disable → change size → Create. There is no resize; creating a new
swapfile replaces the old one (only possible while swap is disabled).

## Filesystem compatibility

| Location on Unraid | Swapfile directly? | Note |
|---|---|---|
| btrfs pool, **single device** | ✅ | nocow (`chattr +C` **before** writing; this rules out compression and checksums), fully allocated, do not snapshot the subvolume |
| btrfs pool, **multi-device with RAID1/0/10 data profile** | ❌ directly | `swapfile must have single data profile`. Only usable via loop mode (workaround, not recommended) |
| btrfs pool, multi-device with `single` data profile | ⚠️ | Only if all extents happen to be on one device (`swapfile must be on one device`). Cannot be influenced, not recommended |
| XFS pool (single device) | ✅ | The simplest case, no nocow ritual needed |
| ZFS pool | ❌ as a file | Swapfiles on ZFS are not supported. Alternative: a zvol as a block device, but see the warning below |
| `/mnt/user/...` (FUSE/shfs overlay) | ❌ never | Not a block-based filesystem. The classic Unraid beginner trap; the kernel refuses it and the plugin's fs check blocks the creation |
| Array disks (`/mnt/diskN`, XFS) | technically ✅, strongly discouraged | Every swap write goes through the parity write path (parity overhead), plus spin-up latency and HDD speed |
| Unassigned Device (XFS) | ✅ | A clean way; the mount point is shown in the UD tab |
| USB boot stick (`/boot`) | ❌ | FAT/exFAT do not support swapfiles; flash wear |
| Network shares (NFS/SMB, `/mnt/remotes`) | ❌ | No fixed block mapping; the kernel refuses swapfiles there |

**Warning about a ZFS zvol:** per the OpenZFS FAQ, even a zvol as a swap device is
**not deadlock-safe** on Linux (openzfs/zfs#7734). The plugin creates it as the FAQ
recommends (`-b <page size>`, `logbias=throughput`, `sync=always`,
`primarycache=metadata`, no auto-snapshots). That lowers the risk but does not
remove it. Where possible use an XFS pool or a small dedicated SSD as a pool.

**Adding a device to a btrfs pool:** when a second device is added to a single-device
btrfs pool, Unraid converts the pool to the RAID1 data profile. An existing swapfile on
that pool can then no longer be enabled (`swapfile must have single data profile` in
dmesg). The plugin cannot prevent this; the next enable or autostart fails with an alert.
Disable swap before changing the pool, then move the swapfile to a single-device pool or
an XFS pool (or use loop mode, see below).

## Binding modes

`direct` (default, recommended) or `loop`. Loop mode is only selectable with
`fs=btrfs`: it binds a loop device to the file so `swapon` skips the btrfs
block-mapping checks (this is how old guides "worked" on RAID1 btrfs).

⚠️ Warning: loop mode (not recommended)

You chose loop mode for a swapfile on btrfs (e.g. on a RAID1 cache).
The kernel refuses a direct swapfile there because swap needs a fixed
block mapping, which btrfs cannot guarantee with several devices or a
RAID data profile ("swapfile must have single data profile" in dmesg).
Loop mode bypasses that check but does not remove its background, and it
is neither tested nor supported:

 - Writes go through the loop device and the btrfs write path. That path
   can itself request memory under memory pressure.
 - The stall risk sits exactly at the moment memory is needed.
 - In the worst case the system locks up instead of relieving itself.

Recommended alternatives: a single-device btrfs pool (nocow), an XFS pool,
or a small dedicated SSD as its own pool.

Direct I/O (`losetup --direct-io=on`, tried automatically with a fallback) lowers
the risk. It remains: in the worst case the system locks up instead of relieving
itself.

## Files

```
swap-manager.plg                  installer manifest (downloads files/ from the version tag)
icon.png                          icon for Community Applications
tools/update-sha256.sh            release helper: SHA256 of every downloaded file into the plg
files/README.md                   plugin description (shown in the plugin manager card)
files/default.cfg                 default settings
files/SwapManager.page            Settings → User Utilities → Swap Manager
files/SwapManagerDash.page        dashboard tile (usage ring, or the history graph when enabled)
files/scripts/swapctl.sh          entry point: dispatch + status/history/selftest
files/scripts/sampler.sh          background sampler for the usage history (24h in RAM)
files/scripts/lib/utils.sh        shared helpers (config validation, notifications, state checks)
files/scripts/lib/swapon.sh       create/enable/autostart logic
files/scripts/lib/swapoff.sh      disable/manual-off/autostop logic
files/event/disks_mounted         emhttpd hook: enable swap after the array mounted the pools
files/event/started               emhttpd hook: second autostart attempt (swapfiles on Unassigned Devices)
files/event/stopping_svcs         emhttpd hook: disable swap before UD and the array unmount their disks
files/event/unmounting_disks      emhttpd hook: safety net, disable swap before the array unmounts
files/include/exec.php            AJAX endpoint (POST only)
files/include/sparkline.php       dashboard swap ring + history data for the graph
files/include/history.js          history graph (settings page + dashboard tile)
```

Settings persist in `/boot/config/plugins/swap-manager/swap-manager.cfg`. Plugin files are
cached on the stick (`/boot/config/plugins/swap-manager/<version>/`) so a boot works
without network. History and flags live in RAM (`/var/lib/swap-manager/`).

## Troubleshooting

- The status box at the bottom of the settings page shows the state and the last log
  lines. The full log is `/var/log/swap-manager.log` (rotated at 1 MB).
- `/usr/local/emhttp/plugins/swap-manager/scripts/swapctl.sh selftest` checks the path
  validation and must print `selftest ok`.

## Releasing (maintainer notes)

1. Change the files, bump `version` in `swap-manager.plg` and add a `CHANGES` entry.
2. Run `tools/update-sha256.sh` - it writes the SHA256 of every downloaded file into the plg.
3. Commit, push, and push a git tag named exactly like the version (e.g. `2026.10.28`):
   the plg downloads its files from that tag, so an update never mixes files of two versions.

The Community Applications template is not in this repository: it lives in
[sognix/unraid-templates](https://github.com/sognix/unraid-templates) (`plugins/swap-manager.xml`).
Its `PluginURL` must stay identical to `pluginURL` in `swap-manager.plg`.

## License

GPL-2.0, see [LICENSE](LICENSE). The icon is derived from the Unraid webGui icon font,
see [NOTICE.md](NOTICE.md).
