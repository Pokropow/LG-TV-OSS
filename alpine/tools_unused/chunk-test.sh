#!/bin/sh
# chunk-test.sh - corroborate the overshoot theory without rebuilding a kernel.
#
# From prop-control.txt, with the module made verbose:
#     process_buf: wr 0x01ffc(8188) rd 0x01c00(7168) data->size 1024
# Only 1020 bytes are available, yet it reads a fixed 1024 chunk. rd overshoots
# wr by 4, (wr - rd) mod 8192 flips to ~8188, and the module drains the whole
# ring in ~500 us, lapping the writer -> XRUN -> EPIPE.
#
# Every wr the kernel announces is 4 short of a 1024 boundary (8188, 1020,
# 3068) because the parked playback patch -- which IS in the running kernel --
# subtracts one frame when hw_avail >= buffer_size.
#
# If the overshoot is the mechanism, making the module's chunk smaller than the
# shortfall's effect should change the failure. process-size is a writable
# property, and prop writes are now PROVEN to land (log-mask 7 -> -1).
#
# Caveat worth stating: process-size may only be read at module construction,
# in which case setting it mid-stream does nothing and this test is
# inconclusive rather than negative. The dmesg 'data->size' values say which.
#
# usage:  sh chunk-test.sh [> /tmp/chunk-test.txt 2>&1]
#         SIZES="1024 512 256" sh chunk-test.sh

set -u
P=/proc/aaudio/processors/dsp2/playback
SIZES="${SIZES:-512 256 128}"
say() { echo "## $*"; }
getprop() { sed -n "s/^ *$2=(int)\([-0-9]*\).*/\1/p" "$1/prop" 2>/dev/null | head -1; }

for SZ in $SIZES; do
	echo; say "================ process-size = $SZ ================"

	speaker-test -D hw:0,0 -c 2 -t sine -l 0 >/tmp/speaker-test.log 2>&1 &
	st=$!
	i=0
	while [ $i -lt 40 ]; do
		set -- "$P"/*/
		[ -d "$1" ] && [ -e "$1/prop" ] && break
		i=$((i + 1)); usleep 100000 2>/dev/null || sleep 1
	done
	set -- "$P"/*/
	if [ ! -d "$1" ]; then say "no instance"; kill $st 2>/dev/null; continue; fi
	D="${1%/}"

	echo "log-mask 4294967295" > "$D/prop" 2>/dev/null
	echo "process-size $SZ"    > "$D/prop" 2>/dev/null
	usleep 300000 2>/dev/null || sleep 1
	say "process-size readback: $(getprop "$D" process-size)  (wrote $SZ)"

	dmesg -c >/dev/null 2>&1
	sleep 3

	say "chunk sizes the module actually used:"
	dmesg | grep -ao 'data->size [0-9]*' | sort | uniq -c | sed 's/^/    /'
	say "wr/rd pairs (last 8):"
	dmesg | grep -ao 'wr 0x[0-9a-f]*([0-9]*) rd 0x[0-9a-f]*([0-9]*)' | tail -8 | sed 's/^/    /'
	say "stalls/underflow:"
	for k in 'no data. wait' 'need more data' 'buf_full' 'wrong read ptr'; do
		printf '    %-20s %s\n' "$k" "$(dmesg | grep -ac "$k")"
	done

	kill $st 2>/dev/null; wait $st 2>/dev/null
	say "speaker-test: $(grep -c 'Broken pipe' /tmp/speaker-test.log) EPIPE in 3s"
	sleep 1
done
