#!/bin/sh
# run-lg-bin.sh - run a stock webOS 32-bit ARM binary on our aarch64 Alpine.
#
# Why this can work: our kernel has CONFIG_COMPAT=y and
# CONFIG_COMPAT_BINFMT_ELF=y, so it can execute 32-bit ARM userspace. Stock's
# whole rootfs is already mounted (for the audio firmware), so nothing needs
# copying -- we invoke stock's own dynamic loader explicitly and point its
# library path at stock's libs:
#
#   <stock>/lib/ld-linux-armhf.so.3 --library-path <stock>/lib:<stock>/usr/lib \
#       <stock>/usr/bin/fwload_audio2 ...
#
# Why bother: fwload_audio2 is what starts the audio DSP cores on stock and is
# NOT in the GPL tree. Running LG's own binary removes the guesswork about
# whether our FWLOAD_IOCTL_RUN does the same thing. fwloader is the firmware
# stager our audfwload replaces, and audpera is whatever firmware_audio.sh
# calls first ("audpera -d").
#
# The stock userspace is spread over more than one partition: the squashfs
# rootfs on mmcblk0p27, and a "bsp" tree on mmcblk0p28 which is where
# fwload_audio2 actually lives (bsp/usr/bin). So search several roots and
# build the library path from all of them.
#
#     mkdir -p /mnt/mmc27 /mnt/mmc28
#     mountpoint -q /mnt/mmc27 || mount -o ro /dev/mmcblk0p27 /mnt/mmc27
#     mountpoint -q /mnt/mmc28 || mount -o ro /dev/mmcblk0p28 /mnt/mmc28
#
# Stock's order is: stage every image with --donot-run, then fwload_audio2:
#
#     NO_RUN=1 AUDFWLOAD=/usr/local/bin/audfwload sh load-audio-fw.sh
#     sh run-lg-bin.sh fwload_audio2
#
# usage:
#     sh run-lg-bin.sh <name-or-path> [args...]
#     sh run-lg-bin.sh --info <name-or-path>     # just report ELF class + deps
#     sh run-lg-bin.sh --find <name>             # where is it?
#
#     ROOTS=/mnt/mmc27:/mnt/mmc28/bsp sh run-lg-bin.sh fwloader -h

set -u

# Colon-separated search roots. bsp trees first: that is where the audio
# tools live, and a bsp copy should win over any rootfs namesake.
ROOTS="${ROOTS:-/mnt/mmc28/bsp:/mnt/mmc27/bsp:/mnt/mmc28:/mnt/mmc27}"

say() { echo "run-lg-bin: $*"; }

INFO_ONLY=0; FIND_ONLY=0
case "${1:-}" in
	--info) INFO_ONLY=1; shift ;;
	--find) FIND_ONLY=1; shift ;;
esac
[ $# -ge 1 ] || { say "usage: run-lg-bin.sh [--info|--find] <name-or-path> [args...]"; exit 2; }

TARGET="$1"; shift

# Mount the stock partitions read-only if they are not up yet. load-audio-fw.sh
# already does this for p27; p28 is the bsp partition.
if [ "${AUTOMOUNT:-1}" = 1 ]; then
	for n in 27 28; do
		d="/mnt/mmc$n"
		mkdir -p "$d" 2>/dev/null
		mountpoint -q "$d" 2>/dev/null && continue
		mount -o ro "/dev/mmcblk0p$n" "$d" 2>/dev/null \
			&& say "mounted /dev/mmcblk0p$n -> $d (ro)" \
			|| say "note: could not mount /dev/mmcblk0p$n (may need -t squashfs/ext4)"
	done
fi

# which roots actually exist
PRESENT=""
for r in $(echo "$ROOTS" | tr ':' ' '); do
	[ -d "$r" ] && PRESENT="$PRESENT $r"
done
[ -n "$PRESENT" ] || { say "ERROR none of these roots exist: $ROOTS"; exit 1; }
say "roots:$PRESENT"

# --- locate the binary -------------------------------------------------------
BIN=""
for r in $PRESENT; do
	case "$TARGET" in
		/*) [ -f "$r$TARGET" ] && { BIN="$r$TARGET"; break; } ;;
		*)  for d in usr/bin bin usr/sbin sbin; do
			[ -f "$r/$d/$TARGET" ] && { BIN="$r/$d/$TARGET"; break; }
		    done
		    [ -n "$BIN" ] && break ;;
	esac
done

if [ -z "$BIN" ]; then
	say "ERROR cannot find '$TARGET' in:$PRESENT"
	say "searching harder (this may take a moment)..."
	for r in $PRESENT; do
		find "$r" -name "$TARGET" -type f 2>/dev/null | sed 's/^/    /'
	done
	exit 1
fi
say "binary: $BIN"

if [ "$FIND_ONLY" = 1 ]; then
	ls -l "$BIN"
	exit 0
fi

# --- ELF class / machine, read straight from the header ----------------------
# e_ident[EI_CLASS] is byte 4: 1 = 32-bit, 2 = 64-bit.
CLASS=$(od -An -tu1 -j4 -N1 "$BIN" 2>/dev/null | tr -d ' ')
case "$CLASS" in
	1) say "ELF class: 32-bit  (needs CONFIG_COMPAT -- we have it)" ;;
	2) say "ELF class: 64-bit  (runs natively, no loader trick needed)" ;;
	*) say "WARN could not read ELF class (got '$CLASS') -- not an ELF?" ;;
esac

# --- shared libraries it names (DT_NEEDED strings live in .dynstr) -----------
say "shared libraries referenced:"
grep -aoE 'lib[A-Za-z0-9_.+-]*\.so[0-9.]*' "$BIN" 2>/dev/null | sort -u | sed 's/^/    /'

# --- find the matching dynamic loader ----------------------------------------
LOADER=""
if [ "$CLASS" = "1" ]; then
	for r in $PRESENT; do
		for c in lib/ld-linux-armhf.so.3 lib/ld-linux.so.3 lib/ld-linux-arm.so.3 \
		         lib/ld-2.*.so usr/lib/ld-linux-armhf.so.3; do
			for f in "$r"/$c; do
				[ -f "$f" ] && { LOADER="$f"; break; }
			done
			[ -n "$LOADER" ] && break
		done
		[ -n "$LOADER" ] && break
	done
	[ -n "$LOADER" ] || {
		say "ERROR no 32-bit loader found. Loaders present in these roots:"
		for r in $PRESENT; do ls "$r"/lib/ld-* "$r"/usr/lib/ld-* 2>/dev/null | sed 's/^/      /'; done
		exit 1
	}
	say "loader: $LOADER"
fi

# library path across every root
LIBPATH=""
for r in $PRESENT; do
	for d in lib usr/lib usr/lib/arm-linux-gnueabihf lib/arm-linux-gnueabihf; do
		[ -d "$r/$d" ] && LIBPATH="${LIBPATH:+$LIBPATH:}$r/$d"
	done
done
say "library path: $LIBPATH"

if [ "$INFO_ONLY" = 1 ]; then
	say "--info given, not executing"
	[ -n "$LOADER" ] && {
		say "would run:"
		echo "    $LOADER --library-path $LIBPATH $BIN $*"
	}
	exit 0
fi

# --- run ----------------------------------------------------------------------
say "running (stderr included; 'error while loading shared libraries' names"
say "any missing lib -- add its directory to LIBPATH or copy it in)"
echo "---8<--- output ---"
if [ -n "$LOADER" ]; then
	"$LOADER" --library-path "$LIBPATH" "$BIN" "$@"
else
	"$BIN" "$@"
fi
rc=$?
echo "--->8--- exit $rc"
exit $rc
