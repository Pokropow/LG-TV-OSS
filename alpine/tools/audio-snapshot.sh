#!/bin/sh
# audio-snapshot.sh - identical snapshot on STOCK and on our kernel, to diff.
#
# STATUS (2026-10-17): AUDIO WORKS. The cause was the SE's OSD volume sitting
# at zero -- `audio-up.sh` now writes "LGSE Var Fn009". Everything below this
# line was written while it was still broken, so its "state of play" is
# history, not current fact. The tool itself is still good for debugging.
#
# READ-ONLY: reads /proc and /dev/mem, writes nothing, sets no control.
#
# Stock reference already established (stock-peek):
#   bc-speaker holds 4ch x 32-bit PCM, L/R duplicated into ch0/ch1, ch2/ch3 zero
#   speaker path = mixer.out2 -> gluepr -> bypass -> dap -> se -> queue
#                  -> outctrlbin -> output_speaker      (se bypass_mode=true)
#   i.e. exactly our SE_INIT=5 / SE_MODE=3 topology.
# Ours is identical in shape and bc-speaker is all zeros, so the difference is
# in module CONFIGURATION, not wiring. The two dumps this adds over stock-peek
# are the ones that can carry it: dsp2/mixerbin (which decides what out2
# contains) and dsp1/dap (which processes it).
#
# usage:  sh audio-snapshot.sh > /tmp/snap-<where>.txt 2>&1
#         (on ours: with a tone playing; on stock: with sound playing)

set -u
say() { echo "## $*"; }
POOL=/proc/hma/audio_buffer0/status
[ -r "$POOL" ] || POOL=/proc/hma/audio_buffer/status

say "===== every audio_buffer chunk, scanned in full ====="
printf '  %-22s %-20s %8s %10s\n' NAME ADDR SIZE_KB NONZERO
awk '{print $1, $2, $NF}' "$POOL" 2>/dev/null | while read -r a s n; do
	case "$n" in aud[0-3]_ram|ipc*|"<null>") continue ;; esac
	kb=$(( s / 1024 )); [ "$kb" -gt 0 ] || kb=1
	nz=$(dd if=/dev/mem bs=1024 skip=$(( a / 1024 )) count="$kb" 2>/dev/null \
		| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c)
	printf '  %-22s %-20s %8s %10s\n' "$n" "$a" "$kb" "$nz"
done

say "===== first bytes of bc-speaker ====="
A=$(awk '$NF == "bc-speaker" { print $1; exit }' "$POOL" 2>/dev/null)
[ -n "$A" ] && dd if=/dev/mem bs=1024 skip=$(( A / 1024 )) count=1 2>/dev/null \
	| od -A x -t x2 | head -6 | sed 's/^/  /'

say "===== dsp2/mixerbin + dsp1 chain properties ====="
for m in dsp2/mixerbin dsp1/dap dsp1/se dsp1/queue dsp1/outctrlbin dsp1/output_speaker dsp1/bypass; do
	for d in /proc/aaudio/processors/$m/*/; do
		[ -e "$d/prop" ] || continue
		echo "  --- ${d#/proc/aaudio/processors/}"
		sed 's/^/      /' "$d/prop"
	done
done

say "===== sndout [SPK] ====="
S=$(find /proc -name sndout 2>/dev/null | head -1)
[ -n "$S" ] && sed -n '1,12p' "$S" | sed 's/^/  /'

say "===== graph edges ====="
cat /proc/aaudio/dot_module_connection 2>/dev/null | grep -E '\->' | sed 's/^/  /'
