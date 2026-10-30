# pxe-mirror-setup

One script that turns a running Debian machine into a PXE boot server with a
local Debian 12 (bookworm) mirror. Alpha: read it before you run it.

    sudo bash pxe-mirror-setup.sh

What it sets up, unattended:

- **proxyDHCP + TFTP** (dnsmasq): your existing DHCP server keeps handing out
  addresses; this box only answers PXE requests. BIOS and UEFI netboot of the
  Debian 12 installer (UEFI uses a GRUB image with the server address built in,
  so it works behind proxyDHCP).
- **Debian mirror** (debmirror) on the largest non-OS disk, mounted on
  `/srv/mirror`. The disk is formatted only if it is blank, unless you set
  `WIPE_MIRROR_DISK=yes`. First sync runs in the background, then nightly via a
  systemd timer. Full amd64 mirror with sources needs about 600 GB.
- **Web interface** (nginx on :80): status page, browsable mirror, preseeds.
- **`pxe-preseed`**: a preseed generator. `sudo pxe-preseed` writes
  `/srv/pxe/preseed/<name>.cfg` and adds a PXE menu entry for it.
  A starter preseed `default` is created with user `user` / password
  `password`: replace it before installing anything you care about.

## Settings

All settings are environment variables at the top of the script, e.g.

    sudo MIRROR_DISK=/dev/sdb MIRROR_SOURCES=no bash pxe-mirror-setup.sh

Common ones: `MIRROR_DISK`, `WIPE_MIRROR_DISK`, `MIRROR_UPSTREAM`,
`MIRROR_DISTS`, `MIRROR_SOURCES`, `START_SYNC`, `PXE_IFACE`. The script is safe
to re-run.

## Requirements

A Debian machine with root/sudo, a wired interface on the LAN you want to boot,
and a second disk for the mirror.
