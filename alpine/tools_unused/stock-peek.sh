#!/bin/sh
# stock-peek.sh - READ-ONLY. Run on STOCK webOS, with sound actually playing.
#
# Why: on our kernel the whole chain is now provably correct --
#   alsa_playback ring            129739 non-zero (real sine)
#   mixerbin out buffers          ~114000 non-zero (live, rising)
#   se bypassed, graph correct, no EPIPE
#   output_speaker out_chain_bc   data size 0x800, rd/wr advancing
#   bc-speaker                    ALL ZEROS
# output_speaker says it writes 2048 bytes a cycle into bc-speaker and that
# memory stays zero. Before concluding output_speaker is broken, check the
# assumption underneath it: that bc-speaker is the buffer the speaker DAC
# reads. If stock ALSO shows bc-speaker as zeros while audible sound plays,
# then it isn't, and several rounds of measurement were aimed at the wrong
# address.
#
# Reads /proc and /dev/mem only. Writes nothing, changes no control.
#
# usage, on stock, as root, WITH SOUND PLAYING:
#     sh stock-peek.sh 2>&1 | tee /tmp/stock-peek.txt

set -u
say() { echo "## $*"; }

POOL=""
for p in /proc/hma/audio_buffer0/status /proc/hma/audio_buffer/status; do
	[ -r "$p" ] && POOL="$p" && break
done
[ -n "$POOL" ] || { say "no HMA pool status found"; ls /proc/hma 2>/dev/null; exit 1; }
say "pool: $POOL"

nz() { # addr size_bytes
	kb=$(( $2 / 1024 )); [ "$kb" -gt 0 ] || kb=1
	dd if=/dev/mem bs=1024 skip=$(( $1 / 1024 )) count="$kb" 2>/dev/null \
		| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c
}

say "===== every bc-* buffer, scanned in full, while sound plays ====="
printf '  %-16s %-20s %8s %10s\n' NAME ADDR SIZE_KB NONZERO
awk '$NF ~ /^bc-/ { print $1, $2, $NF }' "$POOL" | while read -r a s n; do
	printf '  %-16s %-20s %8s %10s\n' "$n" "$a" "$(( s / 1024 ))" "$(nz "$a" "$s")"
done

say "===== first bytes of bc-speaker (is it PCM?) ====="
A=$(awk '$NF == "bc-speaker" { print $1; exit }' "$POOL")
[ -n "$A" ] && dd if=/dev/mem bs=1024 skip=$(( A / 1024 )) count=1 2>/dev/null \
	| od -A x -t x2 | head -8 | sed 's/^/  /'

say "===== driver's view of the speaker output ====="
S=$(find /proc -name sndout 2>/dev/null | head -1)
[ -n "$S" ] && sed -n '1,14p' "$S" | sed 's/^/  /'

say "===== dsp1 output modules (compare against ours) ====="
for d in /proc/aaudio/processors/dsp1/output_speaker/*/ /proc/aaudio/processors/dsp1/se/*/ \
         /proc/aaudio/processors/dsp1/outctrlbin/*/; do
	[ -e "$d/prop" ] || continue
	echo "  --- ${d#/proc/aaudio/processors/}"
	sed 's/^/      /' "$d/prop"
done

say "===== module graph (edges only) ====="
cat /proc/aaudio/dot_module_connection 2>/dev/null | grep -E '\->|phys:' | sed 's/^/  /'
