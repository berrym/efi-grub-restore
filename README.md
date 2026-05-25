# efi-grub-restore

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/berrym/efi-grub-restore?label=release)](https://github.com/berrym/efi-grub-restore/releases/latest)
[![Fedora 42+](https://img.shields.io/badge/Fedora-42%2B-294172?logo=fedora&logoColor=white)](https://fedoraproject.org/)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

Auto-restore `/boot/efi/EFI/fedora/grub.cfg` after Fedora package updates clobber it, on full-disk-encrypted Fedora installs where `/boot` lives **inside** the encrypted btrfs root and the EFI grub.cfg chains into a pinned btrfs snapshot.

If a Fedora `grub2-efi-x64`, `shim-x64`, or related update overwrites your EFI grub.cfg with Fedora's default (no `cryptomount`, no snapshot prefix), GRUB drops to a rescue prompt on next boot and you can't unlock your root. This tool catches the overwrite and rewrites the correct 5-line config from values it derives at runtime, before that next boot.

## The setup this is for

This is **not** for stock Fedora encryption (which keeps `/boot` on a separate unencrypted partition). It's for a manually-built FDE layout that looks like this:

- Single LUKS-encrypted partition holding btrfs.
- `/boot` is a directory inside the encrypted btrfs root — no separate `/boot` partition.
- GRUB unlocks the LUKS volume itself via `cryptomount` before it can read any boot files.
- A specific btrfs snapshot subvolume has been promoted as default and you want GRUB to keep chaining into *that* snapshot's `/boot/grub2/grub.cfg`.

The resulting EFI grub.cfg has the shape:

```
cryptomount -u <LUKS_UUID_NO_DASHES>
search --no-floppy --root-dev-only --fs-uuid --set=dev <BTRFS_FS_UUID>
set prefix=($dev)/<DEFAULT_SUBVOL_PATH>/boot/grub2
export $prefix
configfile $prefix/grub.cfg
```

This tool re-generates exactly that, deriving the three identifiers from the running system every time it runs. There are no hardcoded UUIDs in the code — the same files work on any machine built this way.

## How it works

Three independent triggers, all calling the same idempotent renderer:

1. **inotify path unit** — watches the `/boot/efi/EFI/fedora/` directory. Fires within ~1 second of any in-session write (online `dnf` upgrades, manual `grub2-install`, anaconda re-runs, anything that touches a file in the dir).
2. **libdnf5 `post_transaction` action** — fires at the end of every `dnf5` / PackageKit transaction, **including offline updates** run from `system-update.target`. This is the layer that catches the offline-update case the path unit can't (path units aren't pulled into `system-update.target`).
3. **Boot-time oneshot** — runs once per boot. Belt-and-suspenders for anything missed by the other two.

The renderer (`/usr/local/bin/restore-efi-grub`):

- Derives LUKS UUID via `findmnt -no SOURCE /` → strip `[subvol]` suffix → `cryptsetup status` → `cryptsetup luksUUID`.
- Derives btrfs FS UUID via `findmnt -no UUID /`.
- Derives default subvolume path via `btrfs subvolume get-default /`.
- Renders the desired grub.cfg.
- `cmp`s against the live file. Exits silently if they match; otherwise archives the clobbered version to `/var/log/restore-efi-grub/grub.cfg.clobbered.<ts>` and writes the rendered version atomically (mktemp + rename in the same FAT directory).

## Installation

```bash
git clone git@github.com:berrym/efi-grub-restore.git
cd efi-grub-restore

# Dry-run first — verifies the renderer's derived values match your live file
sudo /home/<you>/.../usr/local/bin/restore-efi-grub --dry-run   # or run it after copying

# If the dry-run says "already matches desired — no action needed", install:
sudo ./install.sh
```

`install.sh` will:

- Place the renderer at `/usr/local/bin/restore-efi-grub`.
- Install three systemd unit files into `/etc/systemd/system/`.
- Install the libdnf5 actions hook into `/etc/dnf/libdnf5-plugins/actions.d/`.
- Warn if `libdnf5-plugin-actions` isn't installed (offline-update coverage requires it; `sudo dnf install libdnf5-plugin-actions`).
- Enable and start `restore-efi-grub.path` (the inotify watcher) and enable `restore-efi-grub-boot.service`.
- Run the renderer once with `--verbose` as post-install verification.

## Verifying it works

```bash
# Dry-run the renderer at any time — never writes.
sudo /usr/local/bin/restore-efi-grub --dry-run

# Confirm the inotify watcher is armed.
systemctl status restore-efi-grub.path     # expect Active: active (waiting)

# Smoke test: clobber the EFI grub.cfg, watch it self-heal.
echo 'broken' | sudo tee /boot/efi/EFI/fedora/grub.cfg
sleep 2
sudo cat /boot/efi/EFI/fedora/grub.cfg
journalctl -t restore-efi-grub -n 5

# Verify the libdnf5 hook fires inside a real transaction.
sudo dnf5 reinstall -y filesystem    # any tiny no-op transaction
journalctl -u restore-efi-grub.service -n 5
```

The renderer logs to the journal only when it writes (i.e., when something was actually wrong). Silent runs mean the file already matched — which is what you want most of the time.

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes the units, hook, and script. Leaves `/var/log/restore-efi-grub/` (clobber archives) and `/boot/efi/EFI/fedora/grub.cfg` (your current EFI config) alone.

## CLI flags

```
restore-efi-grub [--dry-run|-n] [--verbose|-v] [--help|-h]
```

- `--dry-run` — print derived values, the rendered config, and a diff against the live file. Make no changes. Always exits 0.
- `--verbose` — print derived values to stderr during a normal write run. Useful when debugging via the systemd unit (add `--verbose` to `ExecStart=`).

## Escape hatch

If you want to make a one-off intentional change to the live grub.cfg without the watcher reverting you:

```bash
sudo touch /etc/grub-custom/.allow-once
# now make your edit; the next path-unit firing will skip restoring
```

The flag is consumed after one firing.

## Related work

[SysGuides/sysguides-grub-cryptomount-fix](https://github.com/SysGuides/sysguides-grub-cryptomount-fix) solves an overlapping but distinct problem: a Fedora-default EFI grub.cfg with just `cryptomount` prepended. If your setup follows that pattern (Fedora's stock chain into BLS, no pinned-snapshot prefix), use their tool — it's simpler. If your EFI grub.cfg explicitly chains into a snapshot subvolume the way this README describes, you need full-file restoration and this tool is the fit.

## License

MIT — see [LICENSE](LICENSE).
