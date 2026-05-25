#!/bin/bash
# Install the EFI grub.cfg auto-restore stack. Run as root.
#
# Stack layers:
#   1. /usr/local/bin/restore-efi-grub
#        Runtime-derives LUKS UUID, btrfs UUID, default subvolume.
#        Renders the desired grub.cfg and writes if drift detected.
#   2. restore-efi-grub.path / .service
#        inotify watch on /boot/efi/EFI/fedora/grub.cfg — in-session protection.
#   3. /etc/dnf/libdnf5-plugins/actions.d/restore-efi-grub.actions
#        libdnf5 post_transaction hook — covers offline updates
#        (PackageKit / dnf5 offline-upgrade / system-update.target).
#   4. restore-efi-grub-boot.service
#        Oneshot at every boot — belt-and-suspenders.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root (sudo $0)" >&2; exit 1; }

cd "$(dirname "$(readlink -f "$0")")"

install -m 0755 usr/local/bin/restore-efi-grub /usr/local/bin/restore-efi-grub

install -m 0644 etc/systemd/system/restore-efi-grub.path         /etc/systemd/system/restore-efi-grub.path
install -m 0644 etc/systemd/system/restore-efi-grub.service      /etc/systemd/system/restore-efi-grub.service
install -m 0644 etc/systemd/system/restore-efi-grub-boot.service /etc/systemd/system/restore-efi-grub-boot.service

install -d -m 0755 /etc/dnf/libdnf5-plugins/actions.d
install -m 0644 etc/dnf/libdnf5-plugins/actions.d/restore-efi-grub.actions \
                /etc/dnf/libdnf5-plugins/actions.d/restore-efi-grub.actions

# Make sure the actions plugin itself is installed
if ! rpm -q libdnf5-plugin-actions >/dev/null 2>&1; then
    echo
    echo "NOTE: libdnf5-plugin-actions is not installed — the offline-update hook"
    echo "      will not fire until you install it:"
    echo "        sudo dnf install libdnf5-plugin-actions"
    echo
fi

systemctl daemon-reload
systemctl enable --now restore-efi-grub.path
systemctl enable        restore-efi-grub-boot.service

# Post-install verification: run the renderer once. Idempotent — should
# either no-op (file already correct) or restore (file was already wrong).
echo
echo "Post-install verification run:"
/usr/local/bin/restore-efi-grub --verbose || {
    echo "WARNING: renderer exited non-zero — investigate before rebooting." >&2
    exit 1
}
echo "First line of live grub.cfg:"
head -n 1 /boot/efi/EFI/fedora/grub.cfg

echo
echo "Installed."
echo
echo "Pre-flight dry run (no changes, shows what would be written and any drift):"
echo "  sudo /usr/local/bin/restore-efi-grub --dry-run"
echo
echo "Smoke test (clobber and watch it self-heal in-session):"
echo "  echo 'broken' | sudo tee /boot/efi/EFI/fedora/grub.cfg"
echo "  sleep 2; sudo cat /boot/efi/EFI/fedora/grub.cfg"
echo "  journalctl -t restore-efi-grub -n 20"
echo
echo "Verify dnf5 hook fires after a no-op transaction:"
echo "  sudo dnf5 reinstall -y filesystem    # any tiny pkg"
echo "  journalctl -t restore-efi-grub --since '1 minute ago'"
echo
echo "REMINDER: retire /etc/kernel/install.d/90-cryptomount.install once verified."
echo "  sudo mv /etc/kernel/install.d/90-cryptomount.install{,.disabled}"
