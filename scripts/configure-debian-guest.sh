#!/bin/bash
set -euo pipefail

NERDCTL_VERSION="${NERDCTL_VERSION:-2.4.1}"
VM_USER="${1:-tablet}"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root inside the Debian VM."
[ -f /etc/debian_version ] || die "This script is for a Debian guest."
case "$NERDCTL_VERSION" in
    *[!0-9.]* | "") die "NERDCTL_VERSION must contain only digits and dots." ;;
esac
case "$VM_USER" in
    "" | *[!a-zA-Z0-9_.-]*) die "Use a simple existing Debian username." ;;
esac
[ "$VM_USER" != root ] || die "Do not run the VNC desktop as root."
getent passwd "$VM_USER" >/dev/null || die "Debian user '$VM_USER' does not exist."

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    arm64 | amd64) ;;
    *) die "Unsupported Debian architecture: $ARCH" ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl containerd containernetworking-plugins \
    dbus-x11 tigervnc-standalone-server tigervnc-tools xfce4

systemctl enable --now containerd

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ASSET="nerdctl-$NERDCTL_VERSION-linux-$ARCH.tar.gz"
RELEASE_URL="https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION"
curl --fail --location --retry 3 --output "$TMP_DIR/$ASSET" "$RELEASE_URL/$ASSET"
curl --fail --location --retry 3 --output "$TMP_DIR/SHA256SUMS" "$RELEASE_URL/SHA256SUMS"

EXPECTED_SHA="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1 }' "$TMP_DIR/SHA256SUMS")"
[ "${#EXPECTED_SHA}" -eq 64 ] || die "No valid checksum was found for $ASSET."
case "$EXPECTED_SHA" in
    *[!0-9a-fA-F]*) die "The release checksum is malformed." ;;
esac
printf '%s  %s\n' "$EXPECTED_SHA" "$TMP_DIR/$ASSET" | sha256sum --check --status - ||
    die "nerdctl archive checksum verification failed."

tar -tzf "$TMP_DIR/$ASSET" | grep -Fxq nerdctl ||
    die "nerdctl executable was not found in the release archive."
tar -xzf "$TMP_DIR/$ASSET" -C /usr/local/bin nerdctl
chmod 0755 /usr/local/bin/nerdctl

USER_HOME="$(getent passwd "$VM_USER" | cut -d: -f6)"
VNC_DIR="$USER_HOME/.vnc"
install -d -m 0700 -o "$VM_USER" -g "$VM_USER" "$VNC_DIR"
cat > "$VNC_DIR/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
EOF
chown "$VM_USER:$VM_USER" "$VNC_DIR/xstartup"
chmod 0755 "$VNC_DIR/xstartup"

printf '\nEnter a VNC password for %s when prompted.\n' "$VM_USER"
runuser -u "$VM_USER" -- vncpasswd
runuser -u "$VM_USER" -- tigervncserver :1 -localhost no \
    -geometry 1280x800 -SecurityTypes VncAuth

printf '\ncontainerd and nerdctl %s are installed.\n' "$NERDCTL_VERSION"
printf '%s\n' "Start a test container with: nerdctl run --rm docker.io/library/alpine:latest echo ready"
printf '%s\n' "TigerVNC is running on guest port 5901; connect from Termux to 127.0.0.1:5902."
