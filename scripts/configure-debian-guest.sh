#!/bin/bash
set -euo pipefail
export LC_ALL=C

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

if [ -n "${VNC_PASSWORD_B64:-}" ]; then
    VNC_PASSWORD="$(printf '%s' "$VNC_PASSWORD_B64" | base64 --decode)" ||
        die "Could not decode the VNC password."
    [ "${#VNC_PASSWORD}" -eq 8 ] || die "The VNC password must contain exactly 8 characters."
else
    printf 'Enter an 8-character VNC password for %s.\n' "$VM_USER"
    while :; do
        read -r -s -p "VNC password: " VNC_PASSWORD
        printf '\n'
        [ "${#VNC_PASSWORD}" -eq 8 ] || {
            printf '%s\n' "The VNC password must contain exactly 8 characters." >&2
            continue
        }
        read -r -s -p "Confirm VNC password: " VNC_PASSWORD_CONFIRM
        printf '\n'
        [ "$VNC_PASSWORD" = "$VNC_PASSWORD_CONFIRM" ] && break
        printf '%s\n' "Passwords did not match; try again." >&2
    done
fi

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
USER_GROUP="$(id -gn "$VM_USER")"
VNC_DIR="$USER_HOME/.vnc"
install -d -m 0700 -o "$VM_USER" -g "$USER_GROUP" "$VNC_DIR"
cat > "$VNC_DIR/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
EOF
chown "$VM_USER:$USER_GROUP" "$VNC_DIR/xstartup"
chmod 0755 "$VNC_DIR/xstartup"

printf '%s\n' "$VNC_PASSWORD" | runuser -u "$VM_USER" -- vncpasswd -f > "$VNC_DIR/passwd"
chown "$VM_USER:$USER_GROUP" "$VNC_DIR/passwd"
chmod 0600 "$VNC_DIR/passwd"
unset VNC_PASSWORD VNC_PASSWORD_B64 VNC_PASSWORD_CONFIRM

cat > /etc/systemd/system/tigervncserver.service <<EOF
[Unit]
Description=TigerVNC desktop for $VM_USER
After=network.target

[Service]
Type=forking
User=$VM_USER
WorkingDirectory=$USER_HOME
ExecStart=/usr/bin/tigervncserver :1 -localhost no -geometry 1280x800 -SecurityTypes VncAuth -rfbauth $VNC_DIR/passwd -xstartup $VNC_DIR/xstartup
ExecStop=/usr/bin/tigervncserver -kill :1
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now tigervncserver.service
if [ -f /etc/systemd/system/debian-vm-setup.service ]; then
    systemctl disable debian-vm-setup.service
    rm -f /root/.debian-vm-setup.env
fi

printf '\ncontainerd and nerdctl %s are installed.\n' "$NERDCTL_VERSION"
printf '%s\n' "Start a test container with: nerdctl run --rm docker.io/library/alpine:latest echo ready"
printf '%s\n' "TigerVNC starts automatically on guest port 5901; connect from Termux to 127.0.0.1:5902."
