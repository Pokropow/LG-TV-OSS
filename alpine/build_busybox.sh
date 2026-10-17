#!/bin/sh
# Build the static aarch64 busybox that the boot initramfs runs as /init.
#
# Runs INSIDE the aarch64 alpine-builder container, the same way
# build_kexec.sh does:
#
#     cat alpine/build_busybox.sh | docker exec -i alpine-builder sh -s
#
# Output: build/busybox/busybox
set -e
set -x

VERSION=1.38.0
SHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2

# bzip2: busybox ships .tar.bz2 and alpine's stock tar cannot unpack it alone.
apk add bzip2

# /root/build is the host's build/ -- keep the tarball there so a rebuild does
# not re-download it. The source tree is extracted in the container and goes
# away with it.
mkdir -p build
TAR="build/busybox-$VERSION.tar.bz2"
[ -f "$TAR" ] || wget -O "$TAR" "https://busybox.net/downloads/busybox-$VERSION.tar.bz2"
echo "$SHA256  $TAR" | sha256sum -c -

rm -rf "busybox-$VERSION"
tar -xjf "$TAR"
cd "busybox-$VERSION"

make defconfig

# An option is either "CONFIG_X=y" or "# CONFIG_X is not set", never both, so
# each helper has to cope with whichever form defconfig produced.
set_y() { sed -i "s/^# $1 is not set\$/$1=y/; s/^$1=.*\$/$1=y/" .config; }
set_n() { sed -i "s/^$1=y\$/# $1 is not set/" .config; }

# /init is PID 1 in an initramfs with no /lib and no dynamic loader. A
# dynamically linked busybox dies before it can print anything, which on the
# TV is indistinguishable from the kernel failing to boot.
set_y CONFIG_STATIC

# /init resolves root=LABEL=... with findfs, and blkid is what you reach for
# when it does not. Both default to n in defconfig, and their absence shows up
# only on the TV, as "no root device matching LABEL=alpineroot after 15s" --
# fifteen seconds into a boot, pointing nowhere near the cause.
set_y CONFIG_FINDFS
set_y CONFIG_BLKID

# tc has not compiled against current kernel headers for years, and nothing
# in the initramfs shapes traffic.
set_n CONFIG_TC

yes "" | make oldconfig

# -no-pie: alpine's gcc defaults to PIE, and CONFIG_STATIC then produces a
# static-pie (ET_DYN) binary. That needs no loader either and would very
# likely work, but every busybox known to have booted this TV has been plain
# ET_EXEC, and PID 1 refusing to start is debugged over a serial cable. Not
# the place to take an untested difference.
make CFLAGS_EXTRA="-fno-PIE" LDFLAGS="-no-pie" -j"$(nproc)"

# Fail here rather than shipping a binary that cannot run: a silent fallback
# to dynamic linking is invisible until the TV refuses to boot.
file busybox | grep -q "statically linked" || {
	echo "busybox did not link statically:" >&2
	file busybox >&2
	exit 1
}
for sym in CONFIG_FINDFS CONFIG_BLKID CONFIG_SWITCH_ROOT CONFIG_ASH; do
	grep -qx "$sym=y" .config || {
		echo "$sym did not survive oldconfig -- /init needs it" >&2
		exit 1
	}
done

install -D -m 0755 busybox ../build/busybox/busybox
