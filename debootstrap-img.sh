#!/bin/sh
##### -*- mode:shell-script; indent-tabs-mode:nil; sh-basic-offset:2 -*-
# Copyright (c) 2017 Travis Cross <tc@traviscross.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

usage () {
  echo "Usage: $0 [-h]">&2
  echo "    [-d <workdir>]">&2
  echo "    [-f <output_fmt>]">&2
  echo "    [-i <deb_mirror>]">&2
  echo "    [-l <output_size>]">&2
  echo "    [-m <mode>]">&2
  echo "    [-n <nbd_dev>]">&2
  echo "    [-o <output_img>]">&2
  echo "    [-s <deb_suite>]">&2
}

err () {
  echo "Error: $1">&2
  exit 1
}

wdir=""
mode="release"
nbd_dev="/dev/nbd0"
output_fmt="qcow2"
output_img=""
output_size="8G"
deb_variant="minbase"
deb_suite="jessie"
deb_mirror="http://httpredir.debian.org/debian"
while getopts "d:f:hi:l:m:n:o:s:" o; do
  case "$o" in
    d) wdir="$OPTARG" ;;
    f) output_fmt="$OPTARG" ;;
    h) usage; exit 0 ;;
    i) deb_mirror="$OPTARG" ;;
    l) output_size="$OPTARG" ;;
    m) mode="$OPTARG" ;;
    n) nbd_dev="$OPTARG" ;;
    o) output_img="$OPTARG" ;;
    s) deb_suite="$OPTARG" ;;
  esac
done
shift $(($OPTIND-1))

test -n "$output_img" \
  || output_img="vmi-debian-${deb_suite}.${output_fmt}"

set -e
blocked_signals="INT HUP QUIT TERM USR1"

test $(id -u) -eq 0 \
  || err "Error: must be root"

test -n "$wdir" || wdir="./tmp"
rdir="${wdir}/rootfs"
ddir="${wdir}/distro"
idir="${wdir}/img"
traps=""
traps_enabled=true
nbd_dev1="/dev/mapper/${nbd_dev##*/}p1"

add_trap() {
  if $traps_enabled; then
    traps="$1; $traps"
  fi
}
pop_trap() {
  if $traps_enabled; then
    local i="$1"
    test -n "$i" || i=1
    while test "$i" -gt 0; do
      local cmd="${traps%%;*}"
      eval "$cmd"
      traps="${traps#*;}"
      i="$((i-1))"
    done
  fi
}

handle_exit () {
  set +e
  trap - $blocked_signals EXIT
  eval "$traps"
}

vol_id () (eval $(blkid $1 | sed 's/.*://'); echo $UUID)

clean_mount () {
  if mountpoint -q "$wdir"; then
    umount "$wdir" || err "Could not umount tmpfs"
  fi
  if test -d "$wdir"; then
    rmdir "$wdir" || err "Could not remove working directory"
  fi
}

init_mount () {
  echo "## Mounting tmpfs working directory...">&2
  mkdir -p "$wdir" || err "Couldn't create working directory"
  test -d "$wdir" || err "Failed to create working directory"
  mount -t tmpfs -o size=1G,mode=750 none "$wdir" \
    || err "Couldn't mount tmpfs for working directory"
}

debstrap_v () {
  # Test whether debootstrap support --merged-usr
  if debootstrap --merged-usr | head -n1 | grep -q ^I:; then
    debootstrap --merged-usr "$@"
  else
    debootstrap "$@"
  fi
}

debstrap () {
  debstrap_v \
    --include=dbus \
    --variant=$deb_variant \
    $deb_suite \
    "$@" "$deb_mirror"
}

bootstrap () {
  mountpoint -q "$wdir" || init_mount
  echo "## Running debootstrap...">&2
  debstrap "$ddir"
}

build () {
  test -d "$ddir" || bootstrap
  echo "## Building rootfs...">&2
  rm -rf "$rdir"
  cp -Tal "$ddir" "$rdir"
  add_trap "rm -f $rdir/chroot.sh"
  cat > "$rdir"/chroot.sh <<EOF
cat > /etc/apt/apt.conf <<EEOF
// apt.conf
APT::Install-Recommends "0";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
}
EEOF
echo "###> Installing kernel, grub, and base tools...">&2
DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical \
  DEBCONF_NOWARNINGS="yes" DEBCONF_NONINTERACTIVE_SEEN="true" \
  apt-get install -y \
    linux-image-amd64 grub-pc btrfs-tools \
    iproute2 ssh iputils-ping netbase
echo "###> Clearing SSH host keys...">&2
rm -f /etc/ssh/*_key*
echo "###> Configuring GRUB...">&2
cat > /etc/default/grub <<EEOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Debian Linux"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0"
EEOF
echo "###> Enabling systemd-networkd...">&2
cat > /etc/systemd/network/eth0.network <<EEOF
[Match]
Name=eth0
[Network]
DHCP=yes
EEOF
systemctl enable systemd-networkd
echo "###> Using tmpfs as /tmp...">&2
systemctl enable tmp.mount
echo "###> Setting hostname...">&2
echo "vmi" > /etc/hostname
echo "###> Clearing password...">&2
passwd -d root
EOF
  systemd-nspawn -D "$rdir" -- sh /chroot.sh
  pop_trap
  find "$rdir"/var/cache/apt/archives -type f -name "*.deb" \
    | xargs rm -f
}

list_parts () {
  sfdisk -d "$nbd_dev" \
    | awk '/^\// {print $1" "$4" "$6;}' \
    | sed 's/,//g'
}

bind_parts () {
  list_parts | while read dev start len; do
    dmsetup create "${dev##*/}" <<EOF
0 $len linear $nbd_dev $start
EOF
  done
}

unbind_parts () {
  list_parts | while read dev start len; do
    dmsetup remove "${dev##*/}"
  done
}

bind_img () {
  modprobe nbd max_part=16
  add_trap "qemu-nbd -d $nbd_dev"
  qemu-nbd -f "$output_fmt" -c "$nbd_dev" "$output_img"
  add_trap "unbind_parts"
  bind_parts
}

unbind_img () {
  if $traps_enabled; then
    pop_trap 2
  else
    unbind_parts
    qemu-nbd -d "$nbd_dev"
  fi;
}

partition_img () {
  traps_enabled=false
  bind_img
  dd if=/dev/zero of="$nbd_dev" bs=512 count=1
  parted "$nbd_dev" -- mklabel msdos
  parted "$nbd_dev" -- mkpart primary 4096s -1s
  parted "$nbd_dev" -- set 1 boot on
  qemu-nbd -d "$nbd_dev"
  traps_enabled=true
}

format_img () {
  bind_img
  mkfs.btrfs -M "$nbd_dev1"
  sync
  unbind_img
}

mount_img () {
  bind_img
  add_trap "rmdir $idir"
  mkdir -p "$idir"
  add_trap "sync && umount $idir"
  mount -o noatime,compress=zlib "$nbd_dev1" "$idir"
}

umount_img () {
  if $traps_enabled; then
    pop_trap 2 # mount_img
    pop_trap 2 # bind_img
  else
    sync && umount "$idir"
    rmdir "$idir"
    unbind_img
  fi
}

install_rootfs () {
  test -d "$rdir" || build
  echo "## Installing rootfs into $output_img...">&2
  find "$rdir"/var/lib/apt/lists -type f \
    | xargs rm -f
  qemu-img create -f "$output_fmt" \
    "$output_img" "$output_size"
  partition_img
  format_img
  mount_img
  cp -Ta "$rdir" "$idir"
  cat > "$idir"/etc/fstab <<EOF
UUID=$(vol_id "$nbd_dev1") / btrfs noatime,compress=zlib 0 0
EOF
  chmod 644 "$idir"/etc/fstab
  umount_img
}

install_boot () {
  test -f "$output_img" || install_rootfs
  echo "## Making bootable $output_img...">&2
  mount_img
  systemd-nspawn -D "$idir" -- update-initramfs -u
  add_trap "rm -f $idir/chroot.sh"
  cat > "$idir"/chroot.sh <<EOF
mount -t proc none /proc
mount -t devtmpfs none /dev
mount -t devpts none /dev/pts
mount -t tmpfs none /run
mkdir /run/lock
echo "###> Installing grub...">&2
grub-install $nbd_dev
update-grub
umount /run
umount /dev/pts
umount /dev
umount /proc
EOF
  chroot "$idir" sh /chroot.sh
  pop_trap
  umount_img
}

finalize_img () {
  test -f "$output_img" || install_rootfs
  echo "## Finalizing $output_img...">&2
  mount_img
  rm -f "$idir"/etc/ssh/*_key*
  cat > "$idir"/etc/apt/sources.list <<EOF
deb http://httpredir.debian.org/debian $deb_suite main
EOF
  umount_img
}

trap 'exit 1' $blocked_signals
trap handle_exit EXIT

test "$mode" = "clean" && { clean_mount; rm -f "$output_img"; exit 0; }
test "$mode" = "init" && { init_mount; exit 0; }
test "$mode" = "bootstrap" && { bootstrap; exit 0; }
test "$mode" = "build" && { build; exit 0; }
test "$mode" = "bind-img" && { traps_enabled=false; bind_img; exit 0; }
test "$mode" = "unbind-img" && { traps_enabled=false; unbind_img; exit 0; }
test "$mode" = "mount-img" && { traps_enabled=false; mount_img; exit 0; }
test "$mode" = "umount-img" && { traps_enabled=false; umount_img; exit 0; }
test "$mode" = "partition-img" && { partition_img; exit 0; }
test "$mode" = "format-img" && { format_img; exit 0; }
test "$mode" = "install-rootfs" && { install_rootfs; exit 0; }
test "$mode" = "install-boot" && { install_boot; exit 0; }
test "$mode" = "assemble" && { install_boot; exit 0; }
test "$mode" = "finalize" && { finalize_img; exit 0; }
test "$mode" = "release" && { install_boot; finalize_img; clean_mount; exit 0; }
err "Unknown mode"
