#!/bin/bash
# Write the tree built by build-alpine-rootfs.sh to a USB stick.
#
#   sudo ./write-alpine-usb.sh /dev/sdX
#
# DESTROYS the target device. Creates a GPT root partition labelled
# "alpineroot" (ext4) plus a swap partition, and copies the rootfs in.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
HERE="$(cd "$SELF/.." && pwd)"
. "$SELF/config.sh"

DEV="${1:-}"
MNT="$(mktemp -d)"

ROOTFS=build/alpine-rootfs

die() { echo "error: $*" >&2; exit 1; }
[ -n "$DEV" ] || die "usage: $0 /dev/sdX   (the whole device, not a partition)"
[ "$(id -u)" = 0 ] || die "must run as root (mkfs/mount)"
[ -b "$DEV" ] || die "$DEV is not a block device"
case "$DEV" in *[0-9]) die "$DEV looks like a partition; give the whole device";; esac
[ -d "$ROOTFS" ] || die "no rootfs at $ROOTFS -- run build-alpine-rootfs.sh first"
[ -f "$ROOTFS/sbin/rc-local" ] || die "$ROOTFS does not look like a prepared rootfs"

BASE="$(basename "$DEV")"
REMOVABLE="$(cat "/sys/block/$BASE/removable" 2>/dev/null || echo 0)"
SIZE="$(lsblk -bdno SIZE "$DEV" | tr -d ' ')"
MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null | sed 's/ *$//')"

echo
echo "  device   : $DEV"
echo "  model    : ${MODEL:-unknown}"
echo "  size     : $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "$SIZE bytes")"
echo "  removable: $REMOVABLE"
echo "  source   : $ROOTFS"
echo
lsblk "$DEV" || true
echo

# Refuse fixed disks unless overridden -- the common way to lose a laptop.
if [ "$REMOVABLE" != "1" ] && [ "${FORCE:-}" != "1" ]; then
	die "$DEV is not removable. If you are certain, re-run with FORCE=1"
fi

echo "ALL DATA ON $DEV WILL BE DESTROYED."
printf "Type the device name (%s) to confirm: " "$BASE"
read -r CONFIRM
[ "$CONFIRM" = "$BASE" ] || die "not confirmed"

# ---------------------------------------------------------------- partition
echo "==> partitioning"
umount "${DEV}"* 2>/dev/null || true
wipefs -a "$DEV" >/dev/null
sgdisk --zap-all "$DEV" >/dev/null 2>&1 || true
if [ "$SWAP_SIZE" = "0" ]; then
	sgdisk -n 1:0:0 -t 1:8300 -c 1:"$LABEL" "$DEV" >/dev/null
else
	# root takes everything except the tail, swap gets the tail
	sgdisk -n 1:0:-"$SWAP_SIZE" -t 1:8300 -c 1:"$LABEL"     "$DEV" >/dev/null
	sgdisk -n 2:0:0            -t 2:8200 -c 2:"$SWAPLABEL" "$DEV" >/dev/null
fi
partprobe "$DEV" 2>/dev/null || true
sleep 2

partof() {  # $1 = partition number
	if [ -b "${DEV}$1" ]; then echo "${DEV}$1"
	elif [ -b "${DEV}p$1" ]; then echo "${DEV}p$1"
	fi
}
PART="$(partof 1)"
[ -n "$PART" ] || die "cannot find the new root partition on $DEV"

echo "==> mkfs.ext4 $PART (label $LABEL)"
# no metadata_csum_seed / no 64bit keeps it readable by older e2fsprogs on the TV
mkfs.ext4 -q -F -L "$LABEL" -O ^64bit,^metadata_csum_seed "$PART"

SWAPPART=""
if [ "$SWAP_SIZE" != "0" ]; then
	SWAPPART="$(partof 2)"
	[ -n "$SWAPPART" ] || die "cannot find the new swap partition on $DEV"
	echo "==> mkswap $SWAPPART (label $SWAPLABEL, $SWAP_SIZE)"
	mkswap -L "$SWAPLABEL" "$SWAPPART" >/dev/null
fi

# ---------------------------------------------------------------- copy
mount "$PART" "$MNT"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT

echo "==> copying rootfs"
cp -a "$ROOTFS/." "$MNT/"
sync

echo
echo "done. root partition: $PART  (LABEL=$LABEL)"
[ -n "$SWAPPART" ] && echo "      swap partition: $SWAPPART  (LABEL=$SWAPLABEL, $SWAP_SIZE)"
echo "boot with:  root=LABEL=$LABEL"
[ -n "$SWAPPART" ] && echo "for hibernation, add:  resume=LABEL=$SWAPLABEL"
echo "  (needs CONFIG_HIBERNATION=y -- already set -- and the initramfs to"
echo "   resume before mounting root; not wired up yet)"
echo