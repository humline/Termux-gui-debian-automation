#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

if ! command -v pkg >/dev/null 2>&1 || [ -z "${PREFIX:-}" ]; then
    printf '%s\n' "Run this script from Termux." >&2
    exit 1
fi

if [ "$(uname -m)" != "aarch64" ]; then
    printf 'Expected an ARM64 Android host; found %s.\n' "$(uname -m)" >&2
    exit 1
fi

pkg update
pkg install -y qemu-system-aarch64 qemu-utils curl

printf '\nQEMU installed. Next run: %s/scripts/create-debian-vm.sh\n' \
    "$(cd "$(dirname "$0")/.." && pwd)"
