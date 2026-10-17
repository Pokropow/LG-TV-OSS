#!/bin/bash
# Build the small boot initramfs: brings up USB, finds the Alpine root and
# switch_roots into it. This is the piece that lives in /home/root on the TV
# alongside the kernel; everything else is on the USB stick.
#
#   ./build-boot-initramfs.sh          -> boot-initramfs.cpio.gz  (~1MB)
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
# Assets and build outputs live in the project root, one level up.
HERE="$(cd "$SELF/.." && pwd)"
BB="${BUSYBOX:-$HERE/initramfs/bin/busybox}"
ROOT="$HERE/boot-initramfs-root"
OUT="$HERE/boot-initramfs.cpio.gz"

[ -x "$BB" ] || { echo "need an aarch64 busybox at $BB (or set BUSYBOX=)" >&2; exit 1; }

rm -rf "$ROOT"
# One per line: brace expansion is bash-only, and this breaks silently
# under busybox ash by creating a single literally-named directory.
for d in bin sbin proc sys dev mnt/root newroot; do
	mkdir -p "$ROOT/$d"
done
cp "$BB" "$ROOT/bin/busybox"
chmod +x "$ROOT/bin/busybox"

# static busybox: install the applet symlinks now rather than at runtime,
# because /init runs before anything could call `busybox --install`
for a in sh mount umount switch_root sleep echo cat ls mkdir blkid findfs \
         dmesg mknod grep sed awk chroot test seq \
         reboot poweroff halt sync ln rm cp mv vi ps kill df free; do
	ln -sf /bin/busybox "$ROOT/bin/$a"
done
ln -sf /bin/busybox "$ROOT/sbin/switch_root"

cat > "$ROOT/init" <<'INIT'
#!/bin/busybox sh
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
INIT
chmod +x "$ROOT/init"

( cd "$ROOT" && find . | cpio -o -H newc --owner root:root 2>/dev/null ) | gzip -9 > "$OUT"
echo "built: $OUT  ($(du -h "$OUT" | cut -f1))"
