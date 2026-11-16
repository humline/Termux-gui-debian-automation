#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
umask 077
export LC_ALL=C

VM_DIR="${VM_DIR:-$HOME/debian-vm}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_CPUS="${VM_CPUS:-4}"
DISK="$VM_DIR/debian-arm64.qcow2"
ISO="$VM_DIR/debian-arm64-mini.iso"
MODE="${1:-boot}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

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
    install)
        [ -s "$ISO" ] || die "Debian installer ISO not found. Run scripts/create-debian-vm.sh first."
        [ -f "$SCRIPT_DIR/configure-debian-guest.sh" ] ||
            die "Guest provisioner is missing: configure-debian-guest.sh"
        for tool in xorriso cpio openssl gzip; do
            command -v "$tool" >/dev/null 2>&1 ||
                die "Missing $tool. Run scripts/setup-termux-qemu.sh first."
        done
        ;;
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
EFI_VARS="${QEMU_EFI_VARS:-}"
if [ "$(basename "$EFI_CODE")" != QEMU_EFI.fd ]; then
    if [ -z "$EFI_VARS" ]; then
        EFI_VARS="$(find_firmware 'edk2-aarch64-vars.fd' 'edk2-arm-vars.fd' 'AAVMF_VARS.fd' || true)"
    fi
    if [ -z "$EFI_VARS" ] || [ ! -f "$EFI_VARS" ]; then
        die "Matching ARM64 UEFI variable firmware was not found. Set QEMU_EFI_VARS."
    fi
fi

if [ "$MODE" = install ]; then
    VM_USER="${VM_USER:-tablet}"
    case "$VM_USER" in
        "" | *[!a-z0-9_-]* | [!a-z_]*)
            die "VM_USER must start with a lowercase letter or underscore and contain only lowercase letters, digits, underscores, and hyphens."
            ;;
    esac
    [ "$VM_USER" != root ] || die "VM_USER cannot be root."
    [ "${#VM_USER}" -le 32 ] || die "VM_USER must be no more than 32 characters."
    [ -t 0 ] || die "Run install mode from a terminal to enter passwords securely."
    printf 'Installing Debian will erase all data on %s.\n' "$DISK"
    read -r -p "Type ERASE to continue: " ERASE_CONFIRM
    [ "$ERASE_CONFIRM" = ERASE ] || die "Installation cancelled."

    read -r -s -p "Debian password for $VM_USER: " VM_PASSWORD
    printf '\n'
    read -r -s -p "Confirm Debian password: " VM_PASSWORD_CONFIRM
    printf '\n'
    [ "$VM_PASSWORD" = "$VM_PASSWORD_CONFIRM" ] || die "Debian passwords did not match."
    [ "${#VM_PASSWORD}" -ge 8 ] || die "Use a Debian password of at least 8 characters."

    while :; do
        read -r -s -p "VNC password (exactly 8 characters): " VNC_PASSWORD
        printf '\n'
        [ "${#VNC_PASSWORD}" -eq 8 ] ||
            die "The VNC password must contain exactly 8 characters."
        read -r -s -p "Confirm VNC password: " VNC_PASSWORD_CONFIRM
        printf '\n'
        [ "$VNC_PASSWORD" = "$VNC_PASSWORD_CONFIRM" ] && break
        printf '%s\n' "VNC passwords did not match; try again." >&2
    done

    USER_SALT="$(openssl rand -hex 8)"
    USER_PASSWORD_HASH="$(printf '%s\n' "$VM_PASSWORD" | openssl passwd -6 -salt "$USER_SALT" -stdin)"
    VNC_PASSWORD_B64="$(printf '%s' "$VNC_PASSWORD" | base64 | tr -d '\n')"
    unset VM_PASSWORD VM_PASSWORD_CONFIRM VNC_PASSWORD VNC_PASSWORD_CONFIRM
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
    "virtio-blk-pci,drive=vm-disk,bootindex=2"
    "-netdev"
    "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:5902-:5901"
    "-device"
    "virtio-net-pci,netdev=net0"
    -display none
    -serial mon:stdio
)

case "$(basename "$EFI_CODE")" in
    QEMU_EFI.fd)
        QEMU_ARGS+=(-bios "$EFI_CODE")
        ;;
    *)
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
    INSTALL_TMP="$(mktemp -d "$VM_DIR/.install.XXXXXX")"
    chmod 0700 "$INSTALL_TMP"
    trap 'rm -rf "$INSTALL_TMP"' EXIT
    cp "$SCRIPT_DIR/configure-debian-guest.sh" "$INSTALL_TMP/configure-debian-guest.sh"

    cat > "$INSTALL_TMP/preseed.cfg" <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string local
d-i netcfg/wireless_wep string
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string Debian User
d-i passwd/username string $VM_USER
d-i passwd/user-password-crypted password $USER_PASSWORD_HASH
d-i passwd/user-default-groups string audio cdrom video sudo
d-i user-setup/allow-password-weak boolean false
d-i user-setup/encrypt-home boolean false
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i apt-setup/use_mirror boolean true
d-i pkgsel/include string openssh-server sudo ca-certificates curl
tasksel tasksel/first multiselect standard, ssh-server
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda
d-i debian-installer/add-kernel-opts string console=ttyAMA0,115200n8
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string cp /configure-debian-guest.sh /target/usr/local/sbin/configure-debian-guest && chmod 0755 /target/usr/local/sbin/configure-debian-guest && cp /debian-vm-setup.service /target/etc/systemd/system/debian-vm-setup.service && cp /debian-vm-setup.env /target/root/.debian-vm-setup.env && chmod 0600 /target/root/.debian-vm-setup.env && in-target sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyAMA0,115200n8"/' /etc/default/grub && in-target update-grub && in-target grub-install --removable --no-nvram && in-target mkdir -p /etc/systemd/system/multi-user.target.wants && in-target ln -sf /etc/systemd/system/debian-vm-setup.service /etc/systemd/system/multi-user.target.wants/debian-vm-setup.service && printf '\\nDEBIAN_VM_INSTALL_COMPLETE\\n' > /dev/console
EOF
    cat > "$INSTALL_TMP/debian-vm-setup.service" <<EOF
[Unit]
Description=Configure Debian VM packages and desktop
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/root/.debian-vm-setup.env
ExecStart=/usr/local/sbin/configure-debian-guest $VM_USER
RemainAfterExit=yes
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    printf 'VNC_PASSWORD_B64=%s\n' "$VNC_PASSWORD_B64" > "$INSTALL_TMP/debian-vm-setup.env"
    chmod 0600 "$INSTALL_TMP/preseed.cfg" "$INSTALL_TMP/debian-vm-setup.env"
    (
        cd "$INSTALL_TMP"
        printf '%s\n' preseed.cfg configure-debian-guest.sh debian-vm-setup.service \
            debian-vm-setup.env |
            cpio --create --format=newc --quiet > preseed.cpio
    )
    xorriso -osirrox on -indev "$ISO" -extract /initrd.gz "$INSTALL_TMP/initrd.gz"
    gzip -c "$INSTALL_TMP/preseed.cpio" >> "$INSTALL_TMP/initrd.gz"
    cat > "$INSTALL_TMP/grub.cfg" <<'EOF'
set timeout=0
menuentry 'Unattended Debian installation' {
    linux /linux auto=true priority=critical preseed/file=/preseed.cfg console=ttyAMA0,115200n8 ---
    initrd /initrd.gz
}
EOF
    xorriso -indev "$ISO" -outdev "$INSTALL_TMP/install.iso" \
        -map "$INSTALL_TMP/initrd.gz" /initrd.gz \
        -map "$INSTALL_TMP/grub.cfg" /boot/grub/grub.cfg \
        -boot_image any replay
    chmod 0600 "$INSTALL_TMP/initrd.gz" "$INSTALL_TMP/install.iso"
    QEMU_ARGS+=(
        -drive "if=none,file=$INSTALL_TMP/install.iso,media=cdrom,readonly=on,id=installer"
        -device "virtio-scsi-device,id=scsi0"
        -device "scsi-cd,drive=installer,bootindex=1"
        -boot order=d,menu=off
        -no-reboot
    )
else
    QEMU_ARGS+=(-boot order=c,menu=off)
fi

printf '%s\n' "Guest SSH forwarding: 127.0.0.1:2222 -> guest:22"
printf '%s\n' "Guest VNC forwarding: 127.0.0.1:5902 -> guest:5901"
printf '%s\n' "QEMU uses software emulation (TCG); performance depends on the device."
if [ "$MODE" = install ]; then
    printf '%s\n' "Debian will install unattended; QEMU will restart from the installed disk when installation reboots."
    qemu-system-aarch64 "${QEMU_ARGS[@]}" | tee "$INSTALL_TMP/console.log" ||
        die "QEMU failed during the unattended installation."
    grep -q '^DEBIAN_VM_INSTALL_COMPLETE' "$INSTALL_TMP/console.log" ||
        die "The installer exited before completing. Check the console output; the installed disk has not been started."
    printf '\n%s\n' "Installer finished. Starting the installed Debian VM."
    rm -rf -- "$INSTALL_TMP"
    trap - EXIT
    unset USER_PASSWORD_HASH USER_SALT VNC_PASSWORD_B64
    exec bash "$SCRIPT_DIR/run-debian-vm.sh" boot
else
    exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
fi
