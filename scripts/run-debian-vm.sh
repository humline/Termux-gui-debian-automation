#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

VM_DIR="${VM_DIR:-$HOME/debian-vm}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_CPUS="${VM_CPUS:-4}"
DISK="$VM_DIR/debian-arm64.qcow2"
ISO="$VM_DIR/debian-arm64-mini.iso"
MODE="${1:-boot}"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [ -z "${PREFIX:-}" ]; then
    die "Run this script from Termux."
fi
if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    die "Run scripts/setup-termux-qemu.sh first."
fi
[ -f "$DISK" ] || die "VM disk not found. Run scripts/create-debian-vm.sh first."

case "$MODE" in
    install) [ -f "$ISO" ] || die "Installer ISO not found. Run scripts/create-debian-vm.sh first." ;;
    boot) ;;
    *) die "Usage: $0 [install|boot]" ;;
esac
case "$VM_MEMORY_MB:$VM_CPUS" in
    *[!0-9:]* | :* | *:) die "VM_MEMORY_MB and VM_CPUS must be positive integers." ;;
esac
if [ "$VM_MEMORY_MB" -le 0 ] || [ "$VM_CPUS" -le 0 ]; then
    die "VM_MEMORY_MB and VM_CPUS must be positive integers."
fi

find_firmware() {
    local name
    for name in "$@"; do
        local found
        found="$(find "$PREFIX/share" "$PREFIX/etc" -type f -iname "$name" -print -quit 2>/dev/null || true)"
        if [ -n "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    done
    return 1
}

EFI_CODE="${QEMU_EFI_CODE:-}"
if [ -z "$EFI_CODE" ]; then
    EFI_CODE="$(find_firmware 'QEMU_EFI.fd' 'edk2-aarch64-code.fd' 'AAVMF_CODE.fd' || true)"
fi
if [ -z "$EFI_CODE" ] || [ ! -f "$EFI_CODE" ]; then
    die "ARM64 UEFI firmware was not found. Set QEMU_EFI_CODE to its firmware file."
fi

QEMU_ARGS=(
    -machine virt
    -cpu max
    -accel tcg
    -m "$VM_MEMORY_MB"
    -smp "$VM_CPUS"
    "-drive"
    "if=none,file=$DISK,format=qcow2,id=vm-disk"
    "-device"
    "virtio-blk-pci,drive=vm-disk"
    "-netdev"
    "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:5902-:5901"
    "-device"
    "virtio-net-pci,netdev=net0"
    "-device"
    "virtio-gpu-pci"
    -display none
    -vnc 127.0.0.1:1
)

case "$(basename "$EFI_CODE")" in
    QEMU_EFI.fd)
        QEMU_ARGS+=(-bios "$EFI_CODE")
        ;;
    *)
        EFI_VARS="${QEMU_EFI_VARS:-}"
        if [ -z "$EFI_VARS" ]; then
            EFI_VARS="$(find_firmware 'edk2-aarch64-vars.fd' 'edk2-arm-vars.fd' 'AAVMF_VARS.fd' || true)"
        fi
        if [ -z "$EFI_VARS" ] || [ ! -f "$EFI_VARS" ]; then
            die "Matching ARM64 UEFI variable firmware was not found. Set QEMU_EFI_VARS."
        fi
        if [ ! -f "$VM_DIR/efi-vars.fd" ]; then
            cp "$EFI_VARS" "$VM_DIR/efi-vars.fd"
        fi
        QEMU_ARGS+=(
            "-drive"
            "if=pflash,format=raw,readonly=on,file=$EFI_CODE"
            "-drive"
            "if=pflash,format=raw,file=$VM_DIR/efi-vars.fd"
        )
        ;;
esac

if [ "$MODE" = install ]; then
    QEMU_ARGS+=(
        "-drive"
        "if=none,file=$ISO,media=cdrom,readonly=on,id=installer"
        "-device"
        "virtio-scsi-device,id=scsi0"
        "-device"
        "scsi-cd,drive=installer"
        -boot order=d
    )
fi

printf '%s\n' "QEMU VNC console: 127.0.0.1:5901 (display :1)"
printf '%s\n' "Guest SSH forwarding: 127.0.0.1:2222 -> guest:22"
printf '%s\n' "Guest VNC forwarding: 127.0.0.1:5902 -> guest:5901"
printf '%s\n' "QEMU uses software emulation (TCG); performance depends on the device."
exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
