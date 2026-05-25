#!/bin/bash
# Uninstall the efi-grub-restore stack.
#
# Disables and removes the systemd units, the libdnf5 actions hook, and the
# renderer script. Does NOT touch:
#   - /boot/efi/EFI/fedora/grub.cfg          (leave whatever is there in place)
#   - /var/log/restore-efi-grub/             (forensic archives of past clobbers)
#   - /etc/kernel/install.d/90-cryptomount.install.disabled
#                                            (your old hook, retired by install.sh)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root (sudo $0)" >&2; exit 1; }

# Stop and disable units (ignore failures — they may already be gone)
systemctl disable --now restore-efi-grub.path        2>/dev/null || true
systemctl disable        restore-efi-grub-boot.service 2>/dev/null || true

# Remove unit files
rm -f /etc/systemd/system/restore-efi-grub.path
rm -f /etc/systemd/system/restore-efi-grub.service
rm -f /etc/systemd/system/restore-efi-grub-boot.service

# Remove libdnf5 actions hook
rm -f /etc/dnf/libdnf5-plugins/actions.d/restore-efi-grub.actions

# Remove the renderer
rm -f /usr/local/bin/restore-efi-grub

systemctl daemon-reload

echo "Uninstalled."
echo
echo "Left in place (delete manually if you want them gone):"
echo "  /var/log/restore-efi-grub/                                  (clobber archives)"
echo "  /etc/kernel/install.d/90-cryptomount.install.disabled       (your retired hook)"
echo "  /boot/efi/EFI/fedora/grub.cfg                               (your current EFI grub.cfg)"
