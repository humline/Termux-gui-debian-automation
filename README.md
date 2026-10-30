# Termux Debian desktop on Android

Guidance for running Debian on an ARM64 Android tablet, including a OnePlus Pad 3 with Snapdragon 8 Elite.

## Recommendation: Debian in proot

For a responsive Linux desktop and everyday development, start with Debian under **proot** and display it with Termux:X11. Proot runs ARM64 Debian userspace directly on Android's Linux kernel, so it avoids the overhead and setup of a virtual machine. It is not a virtualized Linux kernel: Android remains in control of the kernel, devices, and system services.

Install Termux from [its official installation sources](https://termux.dev/), then in Termux:

```sh
pkg update
pkg install proot-distro
proot-distro install debian
```

For a graphical session, install the Termux:X11 Android app and its Termux package using the [Termux:X11 project instructions](https://github.com/termux/termux-x11). In one Termux session, start its X server:

```sh
termux-x11 :0
```

In another Termux session, log in to Debian with shared temporary storage:

```sh
proot-distro login debian --shared-tmp
```

In Debian, install a desktop. XFCE is the lighter, simpler starting point; `plasma-desktop` is a smaller KDE Plasma installation than the full KDE desktop set, but will use more memory and may need troubleshooting in proot:

```sh
apt update
apt install dbus-x11 xfce4
```

For KDE Plasma, install `dbus-x11` and `plasma-desktop` instead of `xfce4`. Set `DISPLAY=:0` in the Debian session and start the chosen desktop (`dbus-launch --exit-with-session startxfce4` for XFCE, or `dbus-launch --exit-with-session startplasma-x11` for Plasma). Avoid starting a desktop session as root; create and use a regular Debian user if needed. Proot does not provide systemd or a separate kernel, so services and desktop features that depend on them may not work normally.

## When to use QEMU

Choose QEMU only if you specifically need a separate guest kernel or want to experiment with a virtual machine. An ARM64 guest can use the tablet's architecture, but useful speed depends on KVM being available to the QEMU app. Do not assume Android exposes KVM: without it, QEMU has to emulate the guest CPU in software and a KDE desktop can be much slower and consume more battery. QEMU also does not automatically make Android hardware or container support available to the guest.

**In short:** proot is the practical choice for Debian + a light desktop; QEMU is not a performance upgrade for this use case.

## `nerdctl` / Docker containers

`nerdctl` is a command-line client for **containerd**, not a standalone Docker engine. It needs a functioning containerd service and Linux kernel container features. A proot Debian environment shares Android's kernel and cannot provide missing kernel capabilities, namespaces, or cgroup support; installing `nerdctl` alone will not make Docker-style containers work. Rootless mode also depends on host-kernel and user-namespace configuration that may not be available on a stock Android device.

For reliable container work, run containerd/nerdctl or Docker on a Linux server, PC, or cloud VM and connect to it from the tablet. A QEMU guest is only worth testing if its guest kernel has the required features and QEMU has adequate acceleration; validate that before relying on it.

## Visual Studio / VS Code

If you mean **Visual Studio** (the full IDE), it is not a Linux/Android IDE. If you mean **Visual Studio Code**, the most practical tablet option is [code-server](https://github.com/coder/code-server), which serves a VS Code-like editor in the tablet's browser and can run in Debian. The official VS Code desktop Linux build is a separate option for ARM64, but running a full GUI IDE inside proot can have compatibility and resource limitations.

Keep the tablet plugged in for long sessions, monitor memory and heat, and back up Debian files. For installation details and limitations, see [proot-distro](https://github.com/termux/proot-distro), [Termux:X11](https://github.com/termux/termux-x11), and [nerdctl](https://github.com/containerd/nerdctl).
