#!/bin/bash
# pxe-mirror-setup.sh - turn a Debian machine into a PXE + Debian 12 mirror server.
#
#   sudo bash pxe-mirror-setup.sh            # (re-execs itself with sudo if needed)
#
# What it does, unattended:
#   1. installs dnsmasq, nginx, debmirror, ipmitool, vim, mtr-tiny, tcpdump, ...
#   2. finds the big mirror HDD (largest disk that is not the OS disk), formats it
#      ONLY if it is blank, mounts it on /srv/mirror (fstab, by UUID)
#   3. nginx web interface on :80 (status page + browsable mirror + preseeds)
#   4. dnsmasq in proxyDHCP mode (your existing DHCP server keeps handing out IPs)
#      + TFTP serving the Debian 12 (bookworm, currently 12.15) netboot installer,
#      BIOS and UEFI
#   5. full amd64 Debian 12 mirror with debmirror (bookworm, -updates, -backports,
#      -security, all components, installer udebs) - first sync runs in the
#      background as pxe-mirror-sync.service, then nightly via a timer
#   6. installs the preseed generator:  sudo pxe-preseed
#      it writes /srv/pxe/preseed/<name>.cfg and adds a PXE menu entry for it
#
# Settings below can be overridden from the environment, e.g.
#   sudo MIRROR_DISK=/dev/sdb bash pxe-mirror-setup.sh
# Safe to re-run.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then exec sudo -E bash "$0" "$@"; fi

# ---------------------------------------------------------------- settings ---
MIRROR_DISK=${MIRROR_DISK:-auto}          # auto = largest non-OS disk, or e.g. /dev/sdb
WIPE_MIRROR_DISK=${WIPE_MIRROR_DISK:-no}  # yes = format the disk even if it holds data
MIRROR_ROOT=${MIRROR_ROOT:-/srv/mirror}
MIRROR_UPSTREAM=${MIRROR_UPSTREAM:-deb.debian.org}
MIRROR_SECURITY_UPSTREAM=${MIRROR_SECURITY_UPSTREAM:-security.debian.org}
MIRROR_DISTS=${MIRROR_DISTS:-bookworm,bookworm-updates,bookworm-backports}
MIRROR_SECTIONS=${MIRROR_SECTIONS:-main,contrib,non-free,non-free-firmware}
MIRROR_ARCH=${MIRROR_ARCH:-amd64}
MIRROR_SOURCES=${MIRROR_SOURCES:-yes}     # no = binary packages only (about half the size)
MIRROR_SYNC_ONCALENDAR=${MIRROR_SYNC_ONCALENDAR:-*-*-* 03:30:00}
MIN_FREE_GB=${MIN_FREE_GB:-600}           # first sync refuses to start below this (binaries+sources)
START_SYNC=${START_SYNC:-yes}             # no = set up everything but don't start the download
PXE_IFACE=${PXE_IFACE:-auto}              # auto = interface with the default route
DI_DIST=bookworm                          # Debian 12 installer
TFTP_ROOT=/srv/tftp
PXE_DIR=/srv/pxe                          # preseeds + web status page
BASE=/opt/pxe-server
EXTRA_PKGS="ipmitool vim mtr-tiny tcpdump"
# ------------------------------------------------------------------------------

LOG=/var/log/pxe-mirror-setup.log
exec > >(tee -a "$LOG") 2>&1
say() { printf '\n=== %s ===\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
say "pxe-mirror-setup $(date -Is)"

. /etc/os-release
[ "$ID" = debian ] || echo "WARNING: this is $PRETTY_NAME, written for Debian"

# --------------------------------------------------------------- packages ---
say "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	dnsmasq nginx debmirror debian-archive-keyring gnupg curl ca-certificates \
	rsync parted e2fsprogs whiptail openssl iproute2 grub-efi-amd64-bin grub-common $EXTRA_PKGS
# dnsmasq's own resolver would clash with systemd-resolved etc.; we only want TFTP/proxyDHCP
systemctl stop dnsmasq 2>/dev/null || true

# ------------------------------------------------------------ network ---
if [ "$PXE_IFACE" = auto ]; then
	PXE_IFACE=$(ip -o -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
[ -n "$PXE_IFACE" ] || die "no default route; set PXE_IFACE"
CIDR=$(ip -o -4 addr show dev "$PXE_IFACE" | awk '{print $4; exit}')
[ -n "$CIDR" ] || die "no IPv4 address on $PXE_IFACE"
SERVER_IP=${CIDR%/*}
PREFIX=${CIDR#*/}
# network address for proxyDHCP
NET=$(python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network.network_address)" "$CIDR" 2>/dev/null) || {
	IFS=. read -r a b c d <<<"$SERVER_IP"; m=$(( 0xffffffff << (32-PREFIX) & 0xffffffff ))
	NET="$(( a & (m>>24 & 255) )).$(( b & (m>>16 & 255) )).$(( c & (m>>8 & 255) )).$(( d & (m & 255) ))"; }
echo "PXE interface $PXE_IFACE, server $SERVER_IP/$PREFIX, proxyDHCP for $NET"
echo "NOTE: the PXE menus and preseeds contain $SERVER_IP - reserve it on the DHCP server."

# ------------------------------------------------------------- mirror disk ---
say "Mirror disk"
root_src=$(findmnt -no SOURCE /)
os_disk=$(lsblk -no PKNAME "$(readlink -f "$root_src")" 2>/dev/null | head -1)
# LVM/crypt root: walk down to the physical disk
[ -n "$os_disk" ] || os_disk=$(lsblk -sno NAME,TYPE "$root_src" | awk '$2=="disk"{gsub(/[^a-zA-Z0-9]/,"",$1); print $1; exit}')
echo "OS disk: /dev/${os_disk:-?}"

if mountpoint -q "$MIRROR_ROOT"; then
	echo "$MIRROR_ROOT is already a mount point ($(findmnt -no SOURCE "$MIRROR_ROOT")), leaving it alone"
else
	if [ "$MIRROR_DISK" = auto ]; then
		[ -n "$os_disk" ] || die "could not work out which disk holds the OS (live/overlay root?); set MIRROR_DISK=/dev/sdX"
		MIRROR_DISK=$(lsblk -dbno NAME,SIZE,TYPE,RO,RM | awk -v os="$os_disk" \
			'$3=="disk" && $4==0 && $5==0 && $1!=os && $1 !~ /^(loop|sr|zram)/ {print $2, $1}' |
			sort -rn | awk 'NR==1{print "/dev/"$2}')
		[ -n "$MIRROR_DISK" ] || die "no second disk found for the mirror; set MIRROR_DISK=/dev/sdX"
	fi
	[ -b "$MIRROR_DISK" ] || die "$MIRROR_DISK is not a block device"
	[ "$(basename "$MIRROR_DISK")" != "$os_disk" ] || die "$MIRROR_DISK is the OS disk"
	lsblk -no MOUNTPOINTS "$MIRROR_DISK" 2>/dev/null | grep -q . && die "$MIRROR_DISK (or a partition) is mounted somewhere; unmount it or set MIRROR_DISK"
	echo "Mirror disk: $MIRROR_DISK ($(lsblk -dno SIZE,MODEL "$MIRROR_DISK"))"

	part=$(lsblk -lnpo NAME,TYPE "$MIRROR_DISK" | awk '$2=="part"{print $1}' | head -1)
	fs=""
	[ -n "$part" ] && fs=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
	if [ -n "$part" ] && { [ "$fs" = ext4 ] || [ "$fs" = xfs ]; } && [ "$WIPE_MIRROR_DISK" != yes ]; then
		echo "Re-using existing $fs filesystem on $part"
	else
		if [ "$WIPE_MIRROR_DISK" != yes ] && { [ -n "$part" ] || [ -n "$(blkid -p "$MIRROR_DISK" 2>/dev/null)" ]; }; then
			lsblk -o NAME,SIZE,FSTYPE,LABEL "$MIRROR_DISK"
			die "$MIRROR_DISK is not blank and has no ext4/xfs to re-use. Re-run with WIPE_MIRROR_DISK=yes to ERASE it."
		fi
		echo "Formatting $MIRROR_DISK (GPT, one ext4 partition, label debmirror)"
		wipefs -a "$MIRROR_DISK"
		parted -s "$MIRROR_DISK" mklabel gpt mkpart mirror ext4 1MiB 100%
		udevadm settle
		part=$(lsblk -lnpo NAME,TYPE "$MIRROR_DISK" | awk '$2=="part"{print $1}' | head -1)
		mkfs.ext4 -F -L debmirror -m 0 -T largefile4 "$part"
		fs=ext4
	fi
	uuid=$(blkid -o value -s UUID "$part")
	mkdir -p "$MIRROR_ROOT"
	sed -i "\# $MIRROR_ROOT #d" /etc/fstab
	echo "UUID=$uuid $MIRROR_ROOT $fs defaults,noatime,nofail,x-systemd.device-timeout=30 0 2" >> /etc/fstab
	systemctl daemon-reload
	mount "$MIRROR_ROOT"
fi
df -h "$MIRROR_ROOT"
mkdir -p "$MIRROR_ROOT/debian" "$MIRROR_ROOT/debian-security" "$TFTP_ROOT" "$PXE_DIR/preseed" "$BASE"

# ------------------------------------------------------------- config file ---
say "Writing $BASE"
cat > "$BASE/pxe.env" <<EOF
# Written by pxe-mirror-setup.sh $(date -Is). Used by pxe-menu, pxe-mirror-sync, pxe-preseed.
SERVER_IP=$SERVER_IP
PXE_IFACE=$PXE_IFACE
PROXY_NET=$NET
MIRROR_ROOT=$MIRROR_ROOT
MIRROR_UPSTREAM=$MIRROR_UPSTREAM
MIRROR_SECURITY_UPSTREAM=$MIRROR_SECURITY_UPSTREAM
MIRROR_DISTS=$MIRROR_DISTS
MIRROR_SECTIONS=$MIRROR_SECTIONS
MIRROR_ARCH=$MIRROR_ARCH
MIRROR_SOURCES=$MIRROR_SOURCES
MIN_FREE_GB=$MIN_FREE_GB
DI_DIST=$DI_DIST
TFTP_ROOT=$TFTP_ROOT
PXE_DIR=$PXE_DIR
EXTRA_PKGS="$EXTRA_PKGS"
EOF

# ---------------------------------------------- pxe-menu: netboot tree + menus ---
cat > /usr/local/sbin/pxe-menu <<'EOF'
#!/bin/bash
# Rebuild /srv/tftp from the Debian 12 netboot.tar.gz (local mirror once synced,
# upstream before that) and add one menu entry per preseed in /srv/pxe/preseed.
set -euo pipefail
. /opt/pxe-server/pxe.env
READY=$MIRROR_ROOT/.mirror-ready
NB=dists/$DI_DIST/main/installer-amd64/current/images/netboot/netboot.tar.gz
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -f "$READY" ] && [ -f "$MIRROR_ROOT/debian/$NB" ]; then
	src=local; cp "$MIRROR_ROOT/debian/$NB" "$tmp/nb.tgz"
else
	src=upstream; curl -fsSL --retry 3 -o "$tmp/nb.tgz" "https://$MIRROR_UPSTREAM/debian/$NB"
fi
mkdir "$tmp/t"; tar -xzf "$tmp/nb.tgz" -C "$tmp/t"
cp "$tmp/t/version.info" "$PXE_DIR/netboot-version.txt" 2>/dev/null || true

d=debian-installer/amd64
txt=; grub="set timeout=-1   # never auto-boot: automated entries wipe disks
"
for f in "$PXE_DIR"/preseed/*.cfg; do
	[ -e "$f" ] || continue
	n=$(basename "$f" .cfg)
	args="auto=true priority=critical url=http://$SERVER_IP/preseed/$n.cfg netcfg/dhcp_timeout=60"
	txt+=$(printf 'label ps-%s\n\tmenu label Automated install: ^%s (preseed)\n\tkernel %s/linux\n\tappend vga=788 initrd=%s/initrd.gz %s --- quiet\n' "$n" "$n" "$d" "$d" "$args")$'\n'
	grub+="menuentry 'Automated install: $n (preseed)' {
    linux  /$d/linux $args --- quiet
    initrd /$d/initrd.gz
}
"
done
if [ -f "$READY" ]; then
	args="mirror/country=manual mirror/http/hostname=$SERVER_IP mirror/http/directory=/debian mirror/http/proxy= apt-setup/security_host=$SERVER_IP apt-setup/security_path=/debian-security"
	txt+=$(printf 'label localmirror\n\tmenu label Manual install from ^local mirror (%s)\n\tkernel %s/linux\n\tappend vga=788 initrd=%s/initrd.gz %s --- quiet\n' "$SERVER_IP" "$d" "$d" "$args")$'\n'
	grub+="menuentry 'Manual install from local mirror ($SERVER_IP)' {
    linux  /$d/linux $args --- quiet
    initrd /$d/initrd.gz
}
"
fi
# our entries go first, stock Debian entries stay below them
{ printf '%s' "$txt"; cat "$tmp/t/$d/boot-screens/txt.cfg"; } > "$tmp/txt.cfg"
mv "$tmp/txt.cfg" "$tmp/t/$d/boot-screens/txt.cfg"
ENTRY=$grub awk '!done && /^menuentry / { printf "%s", ENVIRON["ENTRY"]; done=1 } { print }' \
	"$tmp/t/$d/grub/grub.cfg" > "$tmp/grub.cfg"
mv "$tmp/grub.cfg" "$tmp/t/$d/grub/grub.cfg"

# UEFI loader with this server's TFTP address built in (proxyDHCP fix, see dnsmasq section)
cat > "$tmp/early.cfg" <<GRUB
set net_default_server=$SERVER_IP
set root=(tftp,$SERVER_IP)
set prefix=(tftp,$SERVER_IP)/$d/grub
configfile (tftp,$SERVER_IP)/$d/grub/grub.cfg
GRUB
grub-mkimage -O x86_64-efi -c "$tmp/early.cfg" -p "(tftp,$SERVER_IP)/$d/grub" -o "$tmp/t/grubx64-pxe.efi" \
	efinet net tftp http normal configfile linux echo test true sleep reboot halt \
	efi_gop efi_uga video_bochs video_cirrus all_video gfxterm font png play
chmod -R a+rX "$tmp/t"
rm -rf "$TFTP_ROOT.old"; [ -d "$TFTP_ROOT" ] && mv "$TFTP_ROOT" "$TFTP_ROOT.old"
mv "$tmp/t" "$TFTP_ROOT"; rm -rf "$TFTP_ROOT.old"
echo "PXE menu rebuilt (netboot from $src, $(grep -c '^label ps-' "$TFTP_ROOT/$d/boot-screens/txt.cfg" || true) preseed entries)"
EOF
chmod 755 /usr/local/sbin/pxe-menu

# ------------------------------------------------- pxe-mirror-sync: debmirror ---
cat > /usr/local/sbin/pxe-mirror-sync <<'EOF'
#!/bin/bash
# Build/refresh the local Debian 12 amd64 mirror, then rebuild the PXE menu.
# First run downloads several hundred GB. FORCE=yes skips the free-space check.
set -euo pipefail
. /opt/pxe-server/pxe.env
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
exec 9>/run/lock/pxe-mirror-sync.lock
flock -n 9 || { echo "a mirror sync is already running" >&2; exit 1; }
mountpoint -q "$MIRROR_ROOT" || { echo "$MIRROR_ROOT is not mounted - refusing to fill the OS disk" >&2; exit 1; }
READY=$MIRROR_ROOT/.mirror-ready
STATUS=$PXE_DIR/sync-status.txt
if [ ! -f "$READY" ] && [ "${FORCE:-no}" != yes ]; then
	free=$(df -BG --output=avail "$MIRROR_ROOT" | tail -1 | tr -dc 0-9)
	if [ "$free" -lt "$MIN_FREE_GB" ]; then
		echo "only ${free} GB free on $MIRROR_ROOT, need ~${MIN_FREE_GB} GB (FORCE=yes to try anyway)" | tee "$STATUS" >&2
		exit 1
	fi
fi
echo "sync running since $(date -Is)" > "$STATUS"
trap 'echo "last sync FAILED at $(date -Is), see journalctl -u pxe-mirror-sync" > "$STATUS"' ERR
opts=(--method=http --rsync-extra=none --diff=none --i18n --getcontents
	--keyring=/usr/share/keyrings/debian-archive-keyring.gpg
	--section="$MIRROR_SECTIONS" --arch="$MIRROR_ARCH")
if [ "$MIRROR_SOURCES" = yes ]; then opts+=(--source); else opts+=(--nosource); fi
[ -t 1 ] && opts+=(--progress)

debmirror "${opts[@]}" --host="$MIRROR_UPSTREAM" --root=debian --dist="$MIRROR_DISTS" \
	--di-dist="$DI_DIST" --di-arch="$MIRROR_ARCH" "$MIRROR_ROOT/debian"
debmirror "${opts[@]}" --host="$MIRROR_SECURITY_UPSTREAM" --root=debian-security \
	--dist="$DI_DIST-security" "$MIRROR_ROOT/debian-security"

date -Is > "$READY"
/usr/local/sbin/pxe-menu
size=$(du -sh "$MIRROR_ROOT/debian" "$MIRROR_ROOT/debian-security" | awk '{printf "%s %s  ", $2, $1}')
echo "last sync OK $(date -Is)  $size" > "$STATUS"
systemctl is-enabled --quiet pxe-mirror-sync.timer || systemctl enable --now pxe-mirror-sync.timer
EOF
chmod 755 /usr/local/sbin/pxe-mirror-sync

cat > /etc/systemd/system/pxe-mirror-sync.service <<EOF
[Unit]
Description=Sync local Debian 12 mirror and refresh PXE boot files
Wants=network-online.target
After=network-online.target
RequiresMountsFor=$MIRROR_ROOT

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pxe-mirror-sync
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=infinity
EOF
cat > /etc/systemd/system/pxe-mirror-sync.timer <<EOF
[Unit]
Description=Nightly Debian mirror sync

[Timer]
OnCalendar=$MIRROR_SYNC_ONCALENDAR
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ----------------------------------------------- pxe-preseed: the generator ---
cat > /usr/local/sbin/pxe-preseed <<'EOF'
#!/bin/bash
# pxe-preseed - generate a Debian 12 preseed for the PXE server.
#   sudo pxe-preseed                 interactive (asks everything)
#   sudo pxe-preseed -n web01 -H web01 -u admin -p 'secret' -k ~/.ssh/id_ed25519.pub \
#        -d /dev/sda -P "nginx htop" -y
#   pxe-preseed -l                   list existing preseeds
#   sudo pxe-preseed -r NAME         remove one
# Writes /srv/pxe/preseed/NAME.cfg (http://SERVER/preseed/NAME.cfg) and adds
# "Automated install: NAME" to the PXE menu. NAME "default" is just a name.
# ipmitool vim mtr-tiny tcpdump openssh-server are always installed.
set -euo pipefail
. /opt/pxe-server/pxe.env
DIR=$PXE_DIR/preseed

NAME=; HOST=; DOMAIN=; USERN=; PASS=; SSHKEY=; DISK=; PKGS=; TZ_=; YES=no; DESKTOP=no
LOCALE=en_US.UTF-8; KEYMAP=us; LVM=no
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; echo "Options: -n name -H hostname -D domain -u user -p password -k ssh-pubkey-file -d disk -P \"pkgs\" -t timezone -L (LVM) -y (no questions)"; exit "${1:-0}"; }
while getopts "n:H:D:u:p:k:d:P:t:Lylr:h" o; do case $o in
	n) NAME=$OPTARG;; H) HOST=$OPTARG;; D) DOMAIN=$OPTARG;; u) USERN=$OPTARG;; p) PASS=$OPTARG;;
	k) SSHKEY=$(cat "$OPTARG");; d) DISK=$OPTARG;; P) PKGS=$OPTARG;; t) TZ_=$OPTARG;; L) LVM=yes;; y) YES=yes;;
	l) ls -l "$DIR"/*.cfg 2>/dev/null || echo "no preseeds yet"; exit 0;;
	r) [ "$(id -u)" = 0 ] || exec sudo "$0" "$@"; rm -v "$DIR/$OPTARG.cfg"; /usr/local/sbin/pxe-menu; exit 0;;
	h) usage;; *) usage 1;; esac; done
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

ask() { # ask VAR "question" default
	local cur=${!1}; [ -n "$cur" ] && return 0
	if [ "$YES" = yes ]; then printf -v "$1" '%s' "$3"; return 0; fi
	read -r -p "$2 [$3]: " cur; printf -v "$1" '%s' "${cur:-$3}"
}
ask NAME     "Preseed name (menu entry / file name)" default
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad name"; exit 1; }
ask HOST     "Hostname of installed machines" "debian"
ask DOMAIN   "Domain (blank = none)" ""
ask USERN    "Admin user (gets sudo, root login disabled)" "user"
ask TZ_      "Timezone" "UTC"
ask DISK     "Install disk (blank = first disk found; IT IS WIPED)" ""
if [ -z "$PASS" ]; then
	if [ "$YES" = yes ]; then PASS=password
	else
		while :; do read -r -s -p "Password for $USERN (blank = 'password'): " PASS; echo
			[ -z "$PASS" ] && { PASS=password; break; }
			read -r -s -p "Again: " p2; echo; [ "$PASS" = "$p2" ] && break; echo "mismatch, try again"; done
	fi
fi
if [ -z "$SSHKEY" ] && [ "$YES" != yes ]; then
	read -r -p "SSH public key file for $USERN (blank = none): " kf
	[ -n "$kf" ] && SSHKEY=$(cat "$kf")
fi
if [ "$YES" != yes ] && [ -z "$PKGS" ]; then
	read -r -p "Use LVM? [y/N]: " a; [[ $a =~ ^[Yy] ]] && LVM=yes
	choices=(htop "" off  curl "" on  wget "" on  git "" off  rsync "" on  tmux "" on  screen "" off
		sudo "" on  net-tools "" off  dnsutils "" on  ethtool "" on  lldpd "" off  nmap "" off
		iperf3 "" off  smartmontools "" on  lm-sensors "" off  nfs-common "" off  cifs-utils "" off
		chrony "" off  unattended-upgrades "" off  qemu-guest-agent "" off  zabbix-agent "" off
		docker.io "" off  nginx "" off  python3 "" off  build-essential "" off  firmware-linux "" off)
	if command -v whiptail >/dev/null && [ -t 0 ]; then
		sel=$(whiptail --title "pxe-preseed: $NAME" --separate-output --checklist \
			"Extra packages (ipmitool vim mtr-tiny tcpdump openssh-server are always installed)" \
			25 78 16 "${choices[@]}" 3>&1 1>&2 2>&3) || sel=""
		PKGS=$(echo $sel)
		if whiptail --yesno "Install a desktop (Xfce)?" 8 50; then DESKTOP=yes; fi
	fi
	read -r -p "Any other packages (space separated, blank = none): " more
	PKGS="$PKGS $more"
fi
PKGS=$(echo sudo openssh-server $EXTRA_PKGS $PKGS | tr ' ' '\n' | awk 'NF && !s[$0]++' | xargs)
HASH=$(openssl passwd -6 "$PASS")

if [ -f "$MIRROR_ROOT/.mirror-ready" ]; then MH=$SERVER_IP; SH=$SERVER_IP; SP=/debian-security
else MH=deb.debian.org; SH=security.debian.org; SP=/debian-security; fi
tasks="standard, ssh-server"; [ "$DESKTOP" = yes ] && tasks="standard, ssh-server, xfce-desktop"
if [ "$LVM" = yes ]; then method=lvm; else method=regular; fi
LATE="in-target usermod -aG sudo $USERN;"
if [ -n "$SSHKEY" ]; then
	LATE="$LATE in-target install -d -m 700 -o $USERN -g $USERN /home/$USERN/.ssh; echo '$SSHKEY' > /target/home/$USERN/.ssh/authorized_keys; in-target chown $USERN:$USERN /home/$USERN/.ssh/authorized_keys; in-target chmod 600 /home/$USERN/.ssh/authorized_keys;"
fi
LATE="$LATE true"

mkdir -p "$DIR"
out=$DIR/$NAME.cfg
cat > "$out" <<PRESEED
# Debian 12 (bookworm) preseed "$NAME" - generated by pxe-preseed $(date -Is)
# Served as http://$SERVER_IP/preseed/$NAME.cfg . Re-run pxe-preseed to change it.
d-i debian-installer/locale string $LOCALE
d-i keyboard-configuration/xkb-keymap select $KEYMAP
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $HOST
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/hostname string $HOST
d-i hw-detect/load_firmware boolean true

d-i mirror/country string manual
d-i mirror/http/hostname string $MH
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string bookworm
d-i apt-setup/non-free-firmware boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true
d-i apt-setup/services-select multiselect security, updates
d-i apt-setup/security_host string $SH
d-i apt-setup/security_path string $SP

d-i passwd/root-login boolean false
d-i passwd/user-fullname string $USERN
d-i passwd/username string $USERN
d-i passwd/user-password-crypted password $HASH

d-i clock-setup/utc boolean true
d-i time/zone string $TZ_
d-i clock-setup/ntp boolean true

$( [ -n "$DISK" ] && echo "d-i partman-auto/disk string $DISK" || echo "# no disk set: first disk found is used")
d-i partman-auto/method string $method
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-efi/non_efi_system boolean true
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/mount_style select uuid

d-i base-installer/kernel/image string linux-image-amd64
tasksel tasksel/first multiselect $tasks
d-i pkgsel/include string $PKGS
d-i pkgsel/upgrade select full-upgrade
d-i pkgsel/update-policy select none
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${DISK:-default}

d-i preseed/late_command string $LATE
d-i finish-install/reboot_in_progress note
PRESEED
chmod 644 "$out"
/usr/local/sbin/pxe-menu
echo
echo "Wrote $out"
echo "  URL:      http://$SERVER_IP/preseed/$NAME.cfg"
echo "  Packages: $PKGS"
echo "  Mirror:   $MH"
echo "PXE boot a machine and pick 'Automated install: $NAME (preseed)'. It WIPES ${DISK:-the first disk}."
EOF
chmod 755 /usr/local/sbin/pxe-preseed

# ----------------------------------------------------------------- dnsmasq ---
say "dnsmasq (proxyDHCP + TFTP)"
# UEFI: Debian's signed GRUB reads the TFTP server only from the main DHCP reply,
# which in proxyDHCP mode does not have it, so it stops at a grub> prompt.
# grubx64-pxe.efi (built by pxe-menu) has this server's address built in.
# It is not signed: Secure Boot must be off. UEFI_LOADER=signed uses Debian's.
if [ "${UEFI_LOADER:-custom}" = signed ]; then UEFI_BOOTFILE=debian-installer/amd64/bootnetx64.efi
else UEFI_BOOTFILE=grubx64-pxe.efi; fi
cat > /etc/dnsmasq.d/pxe.conf <<EOF
# Written by pxe-mirror-setup.sh. proxyDHCP: the existing DHCP server gives out
# addresses, we only add the PXE boot info. DNS is off (port=0).
port=0
interface=$PXE_IFACE
bind-dynamic
log-dhcp
enable-tftp
tftp-root=$TFTP_ROOT
dhcp-range=$NET,proxy
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
pxe-service=x86PC,"Debian 12 network install (BIOS)",pxelinux
pxe-service=X86-64_EFI,"Debian 12 network install (UEFI)",$UEFI_BOOTFILE
pxe-service=BC_EFI,"Debian 12 network install (UEFI)",$UEFI_BOOTFILE
EOF
# don't let dnsmasq take over the host's resolv.conf
sed -i 's/^#\?DNSMASQ_EXCEPT=.*/DNSMASQ_EXCEPT="lo"/' /etc/default/dnsmasq 2>/dev/null || true
grep -q '^DNSMASQ_EXCEPT' /etc/default/dnsmasq || echo 'DNSMASQ_EXCEPT="lo"' >> /etc/default/dnsmasq
dnsmasq --test

# --------------------------------------------------------- default preseed ---
# A generic starter preseed so the menu has an automated entry: hostname debian,
# no domain, user "user" / password "password", UTC. Replace it with:
#   sudo pxe-preseed -n default
if [ ! -f "$PXE_DIR/preseed/default.cfg" ]; then
	/usr/local/sbin/pxe-preseed -y -n default -H debian -u user -p password -t UTC >/dev/null
	echo "Starter preseed 'default' written (user 'user', password 'password' - change it after install)"
else
	/usr/local/sbin/pxe-menu
fi

# ---------------------------------------------------------- nginx web UI ---
say "nginx web interface"
cat > "$PXE_DIR/index.html" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>PXE + mirror $SERVER_IP</title>
<style>body{font-family:sans-serif;max-width:50em;margin:2em auto;line-height:1.5}
code,pre{background:#eee;padding:.1em .3em}iframe{width:100%;height:3em;border:1px solid #ccc}</style></head><body>
<h1>PXE + Debian 12 mirror</h1>
<p>Server <b>$SERVER_IP</b> &mdash; PXE boot any machine on this LAN to get the Debian 12 installer.</p>
<ul>
<li><a href="/debian/">/debian/</a> &mdash; Debian 12 amd64 mirror ($MIRROR_DISTS)</li>
<li><a href="/debian-security/">/debian-security/</a> &mdash; bookworm-security</li>
<li><a href="/preseed/">/preseed/</a> &mdash; preseed files (create with <code>sudo pxe-preseed</code>)</li>
<li><a href="/netboot-version.txt">netboot-version.txt</a> &mdash; installer build in use</li>
</ul>
<h2>Mirror sync status</h2><iframe src="/sync-status.txt"></iframe>
<h2>Use the mirror on a Debian 12 machine</h2>
<pre>deb http://$SERVER_IP/debian bookworm main contrib non-free non-free-firmware
deb http://$SERVER_IP/debian bookworm-updates main contrib non-free non-free-firmware
deb http://$SERVER_IP/debian-security bookworm-security main contrib non-free non-free-firmware</pre>
</body></html>
EOF
[ -f "$PXE_DIR/sync-status.txt" ] || echo "not synced yet" > "$PXE_DIR/sync-status.txt"
cat > /etc/nginx/sites-available/pxe-mirror <<EOF
# Written by pxe-mirror-setup.sh
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root $MIRROR_ROOT;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    location = /                   { root $PXE_DIR; try_files /index.html =404; }
    location = /sync-status.txt    { root $PXE_DIR; default_type text/plain; add_header Cache-Control no-cache; }
    location = /netboot-version.txt { root $PXE_DIR; default_type text/plain; }
    location /preseed/             { root $PXE_DIR; default_type text/plain; }
    location ~ /\.                 { deny all; }
}
EOF
ln -sf ../sites-available/pxe-mirror /etc/nginx/sites-enabled/pxe-mirror
rm -f /etc/nginx/sites-enabled/default
nginx -t

# ---------------------------------------------------------------- services ---
say "Starting services"
systemctl daemon-reload
systemctl enable dnsmasq nginx
systemctl restart dnsmasq nginx
if command -v ufw >/dev/null && ufw status | grep -q active; then
	ufw allow 80/tcp; ufw allow 69/udp; ufw allow 67/udp; ufw allow 4011/udp
fi

if [ "$START_SYNC" = yes ]; then
	if [ -f "$MIRROR_ROOT/.mirror-ready" ]; then
		systemctl enable --now pxe-mirror-sync.timer
		echo "Mirror already synced; nightly timer enabled."
	else
		systemctl start --no-block pxe-mirror-sync.service
		echo "First mirror sync started in the background (several hundred GB; hours to days)."
	fi
fi

say "Done"
cat <<EOF
  Web interface:    http://$SERVER_IP/
  PXE:              proxyDHCP on $PXE_IFACE, TFTP $TFTP_ROOT, Debian 12 netboot ($(head -1 "$PXE_DIR/netboot-version.txt" 2>/dev/null || echo bookworm))
  Mirror:           $MIRROR_ROOT on $(findmnt -no SOURCE "$MIRROR_ROOT")
  Watch the sync:   journalctl -fu pxe-mirror-sync
  New preseed:      sudo pxe-preseed        (list: pxe-preseed -l)
  Rebuild menus:    sudo pxe-menu
  Until the first sync finishes, installs use deb.debian.org; afterwards
  re-run 'sudo pxe-preseed' for each preseed so it points at this mirror.
  Log of this run:  $LOG
EOF
