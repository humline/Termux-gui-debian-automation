#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

if ! command -v qemu-img >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "Run scripts/setup-termux-qemu.sh first." >&2
    exit 1
fi

VM_DIR="${VM_DIR:-$HOME/debian-vm}"
DISK_SIZE="${DISK_SIZE:-32G}"
DEBIAN_NETBOOT_URL="${DEBIAN_NETBOOT_URL:-https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/mini.iso}"
ISO="$VM_DIR/debian-arm64-mini.iso"
DISK="$VM_DIR/debian-arm64.qcow2"

mkdir -p "$VM_DIR"
chmod 700 "$VM_DIR"

if [ ! -s "$ISO" ]; then
    printf 'Downloading Debian ARM64 installer to %s\n' "$ISO"
    curl --fail --location --retry 3 --output "$ISO.partial" "$DEBIAN_NETBOOT_URL"
    mv "$ISO.partial" "$ISO"
fi

if [ ! -e "$DISK" ]; then
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
else
    printf 'Keeping existing VM disk: %s\n' "$DISK"
fi

printf '\nVM files are in %s\n' "$VM_DIR"
printf 'Install Debian: scripts/run-debian-vm.sh install\n'
