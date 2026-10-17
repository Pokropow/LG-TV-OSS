#!/bin/busybox sh
# boot-initramfs-init.sh - the initramfs /init.
#
# Copied verbatim to /init by build-boot-initramfs.sh; it is NOT sourced or
# rewritten, so what you read here is exactly what PID 1 executes on the TV.
#
# Runs against the static busybox in /bin, before any dynamic loader exists.
# Keep it to applets that are symlinked in build-boot-initramfs.sh -- an
# unlisted applet fails at the worst possible moment, with no shell to debug
# from beyond the fail() fallback below.
export PATH=/bin:/sbin

/bin/busybox mount -t proc     proc     /proc
/bin/busybox mount -t sysfs    sysfs    /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null

log()  { echo "[boot] $*"; }
fail() { echo "[boot] FAILED: $*"; echo "[boot] dropping to shell -- 'reboot -f' to restart, 'blkid' to inspect disks"; exec /bin/sh; }

# The LG USB controller is behind a deferred user_initcall -- without this
# no USB device ever appears. See drivers/soc/lg1k/usb.c: user_initcall_grp("USB",...)
if [ -w /proc/usercalls ]; then
	log "starting USB subsystem"
	echo USB > /proc/usercalls
fi

log "Disable cpu hotplug"
echo 0 > /proc/lg/pm/mp_enable

# root=... from the kernel cmdline; accepts LABEL=, UUID= or a device path.
ROOTSPEC=$(sed -n 's/.*\broot=\([^ ]*\).*/\1/p' /proc/cmdline)
[ -n "$ROOTSPEC" ] || ROOTSPEC="LABEL=alpineroot"
ROOTFLAGS=$(sed -n 's/.*\brootflags=\([^ ]*\).*/\1/p' /proc/cmdline)
log "looking for root=$ROOTSPEC"

DEV=""
i=0
while [ $i -lt 150 ]; do          # ~15s; USB enumeration is not instant
	case "$ROOTSPEC" in
		LABEL=*|UUID=*|PARTUUID=*) DEV=$(findfs "$ROOTSPEC" 2>/dev/null) ;;
		*)                         [ -b "$ROOTSPEC" ] && DEV="$ROOTSPEC" ;;
	esac
	[ -n "$DEV" ] && [ -b "$DEV" ] && break
	DEV=""
	sleep 0.1
	i=$((i+1))
done

[ -n "$DEV" ] || fail "no root device matching $ROOTSPEC after 15s (is the stick plugged in?)"
log "found $DEV"

mount -o rw${ROOTFLAGS:+,$ROOTFLAGS} "$DEV" /newroot || fail "mount $DEV"
[ -x /newroot/sbin/init ] || fail "$DEV has no /sbin/init -- wrong partition?"

# hand the pseudo-filesystems over rather than remounting them on the far side
mount --move /dev  /newroot/dev  2>/dev/null
mount --move /proc /newroot/proc 2>/dev/null
mount --move /sys  /newroot/sys  2>/dev/null

log "switch_root -> $DEV"
exec switch_root /newroot /sbin/init
