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
BB="${BUSYBOX:-$HERE/build/busybox/busybox}"
ROOT="/tmp/boot-initramfs-root"
OUT="$HERE/build/boot-initramfs.cpio.gz"

[ -x "$BB" ] || {
	echo "no aarch64 busybox at $BB" >&2
	echo "build it with:  sh alpine/build.sh   (from the project root)" >&2
	echo "or point BUSYBOX= at a static aarch64 binary you already have" >&2
	exit 1
}

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
APPLETS="sh mount umount switch_root sleep echo cat ls mkdir blkid findfs
         dmesg mknod grep sed awk chroot test seq
         reboot poweroff halt sync ln rm cp mv vi ps kill df free"

# A symlink to an applet this busybox was not built with is a dead link that
# nothing notices until /init needs it, mid-boot, with no way to debug. Read
# the applet table out of the binary rather than running it: the binary is
# aarch64, and executing it here depends on qemu binfmt, which is both
# optional and -- observed while writing this -- occasionally flaky.
# Dump the table once to a file and grep the file: `strings ... | grep -q`
# would have grep exit on the first match, kill strings with SIGPIPE, and
# -o pipefail then reports every single applet as missing.
APPLET_LIST="$(mktemp)"
trap 'rm -f "$APPLET_LIST"' EXIT
# -n 2, because strings defaults to a 4-character minimum and would hide
# sh, ls, ln, rm, cp, mv, vi, ps and df -- half the list. This is a sanity
# check on a NUL-separated name table, not a proof: a two-letter name could
# in principle match some unrelated run of bytes.
strings -a -n 2 "$BB" > "$APPLET_LIST"
missing=""
for a in $APPLETS; do
	grep -qx "$a" "$APPLET_LIST" || missing="$missing $a"
done
[ -z "$missing" ] || {
	echo "busybox at $BB lacks these applets:$missing" >&2
	echo "enable them in alpine/build_busybox.sh and rebuild" >&2
	exit 1
}

for a in $APPLETS; do
	ln -sf /bin/busybox "$ROOT/bin/$a"
done
ln -sf /bin/busybox "$ROOT/sbin/switch_root"

# The init is a file of its own rather than a heredoc: it is the thing that
# actually runs as PID 1 on the TV, and it is worth being able to read, diff
# and shellcheck it without the build script in the way.
install -m 0755 "$SELF/boot-initramfs-init.sh" "$ROOT/init"

( cd "$ROOT" && find . | cpio -o -H newc --owner root:root 2>/dev/null ) | gzip -9 > "$OUT"
echo "built: $OUT  ($(du -h "$OUT" | cut -f1))"
