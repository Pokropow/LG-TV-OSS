#!/bin/sh
# Build the Alpine root filesystem tree for the TV, ready to be written to a
# USB stick by write-alpine-usb.sh.
#
#   sudo ./build-alpine-rootfs.sh
#
# Downloads the current Alpine minirootfs, unpacks it, and applies overlay/
# on top. Touches no block devices. Needs root only because the tarball
# carries ownership and device nodes.
#
# This script is only to be used in docker! It needs aarch64 emulation!
set -eu
# pipefail is not POSIX; busybox ash and bash have it, dash does not.
(set -o pipefail 2>/dev/null) && set -o pipefail || true

SELF="$(cd "$(dirname "$0")" && pwd)"
# Assets and build outputs live in the project root, one level up.
HERE="$(cd "$SELF/.." && pwd)"
. "$SELF/config.sh"

OVERLAY="${OVERLAY:-$SELF/overlay}"

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root (the tarball has ownership and device nodes)"
[ -d "$OVERLAY" ] || die "overlay not found: $OVERLAY"

# ---------------------------------------------------------------- fetch
# edge rolls, so there is no stable minirootfs filename. latest-releases.yaml
# names the current one and carries its sha256. Override with TARBALL=... .
RELDIR="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ARCH}"
if [ -z "${TARBALL:-}" ]; then
	echo "==> looking up the current $ALPINE_BRANCH minirootfs"
	YAML="$(curl -sfL "$RELDIR/latest-releases.yaml" || true)"
	TARBALL="$(printf '%s\n' "$YAML" | awk '/flavor: alpine-minirootfs/{f=1} f && /^[[:space:]]*file:/ {print $2; exit}')"
	SHA256="$(printf '%s\n' "$YAML" | awk '/flavor: alpine-minirootfs/{f=1} f && /^[[:space:]]*sha256:/ {print $2; exit}')"
fi
[ -n "${TARBALL:-}" ] || die "could not determine the $ALPINE_BRANCH minirootfs; set TARBALL=... by hand"

if [ ! -f "$HERE/$TARBALL" ]; then
	echo "==> downloading $TARBALL"
	curl -fL -o "$HERE/$TARBALL" "$RELDIR/$TARBALL"
fi

if [ -n "${SHA256:-}" ]; then
	echo "==> verifying checksum"
	echo "$SHA256  $HERE/$TARBALL" | sha256sum -c - >/dev/null \
		|| die "checksum mismatch on $TARBALL -- delete it and retry"
else
	echo "==> WARNING: no checksum available, skipping verification"
fi

# ---------------------------------------------------------------- unpack
echo "==> unpacking into $ROOTFS"
mkdir -p "$ROOTFS"
tar -xzf "$HERE/$TARBALL" -C "$ROOTFS"
# Listed one per line on purpose: brace expansion is a bash feature, and this
# script also runs under busybox ash inside the build container, where
# "$ROOTFS"/{a,b,c} is taken literally and creates one absurdly named directory.
for d in proc sys dev run tmp mnt root var/lib lib/firmware usr/local/bin etc/profile.d; do
	mkdir -p "$ROOTFS/$d"
done
chmod 1777 "$ROOTFS/tmp"

# ---------------------------------------------------------------- overlay
echo "==> applying overlay"
cp -a "$OVERLAY/." "$ROOTFS/"

# The only per-install values. Everything else in overlay/ is literal.
sed -i -e "s|@LABEL@|$LABEL|g" -e "s|@SWAPLABEL@|$SWAPLABEL|g" "$ROOTFS/etc/fstab"
sed -i -e "s|@BRANCH@|$ALPINE_BRANCH|g" "$ROOTFS/etc/apk/repositories"
[ "$SWAP_SIZE" = "0" ] && sed -i "/swap/d" "$ROOTFS/etc/fstab"

echo "$TV_HOSTNAME" > "$ROOTFS/etc/hostname"

# ---------------------------------------------------------------- extras
for t in fbtest ucom; do
	[ -f "$HERE/$t" ] && install -m755 "$HERE/$t" "$ROOTFS/usr/bin/" && echo "==> included $t"
done
[ -d "$HERE/initramfs/lib/firmware" ] && cp -a "$HERE/initramfs/lib/firmware/." "$ROOTFS/lib/firmware/"

# ---------------------------------------------------------------- tools
# tools/*.c are built here rather than cross-compiled on the host: they have
# to be aarch64 + musl, and the LG SDK is glibc with no static libc, so it
# cannot produce anything that runs under Alpine. This script already runs in
# an aarch64 container for the chroot/apk step, so cc(1) here is the right
# compiler -- but guard it, because building on an x86 host would silently
# produce binaries the TV cannot execute.
if [ "$(uname -m)" = "aarch64" ] && command -v cc >/dev/null 2>&1; then
	for src in "$SELF"/tools/*.c; do
		[ -e "$src" ] || continue
		out="$ROOTFS/usr/local/bin/$(basename "${src%.c}")"
		echo "==> building $(basename "$src")"
		cc -O2 -Wall -o "$out" "$src" || die "failed to build $src"
	done
else
	echo "==> WARNING: not aarch64 or no compiler, skipping tools/"
fi

chroot $ROOTFS apk update
chroot $ROOTFS apk add $(cat packages.txt | grep -o '^[^#]*')

mkdir -p /root/build/alpine-rootfs/
rm -rf /root/build/alpine-rootfs/*
mv $ROOTFS/* /root/build/alpine-rootfs/
