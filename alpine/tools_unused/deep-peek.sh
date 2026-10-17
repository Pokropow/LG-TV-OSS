#!/bin/sh
# deep-peek.sh - scan WHOLE buffers, not just their first 2 KiB.
#
# Correction to the earlier scan: it sampled 2 KiB per chunk. For bc-speaker
# (8 KiB, written in 2 KiB chunks at offsets 0x0000/0x1000) that is
# representative. For the mixerbin shared buffers it is NOT -- those are
# 256 KiB and the write pointer can be anywhere in them, so the low non-zero
# counts reported for 0x86a55000 / 0x86a95000 / 0x86ad5000 proved nothing and
# the conclusion drawn from them ("the mixer output is silent") was unfounded.
#
# The graph (dump_module_connection) is:
#   playback -> srcbin -> sola -> lipsync -> gain -> fader -> delay -> gain
#            -> mixerbin.in4
#   mixerbin.out2 -> gluepw_04110003 -> shared_buf 0x86ad5000
#            -> gluepr_03100003 -> bypass -> dap -> se -> queue
#            -> outctrlbin -> output_speaker -> bc-speaker
# so 0x86ad5000 is the exact hand-off from dsp2 to dsp1. If it holds audio and
# bc-speaker does not, the signal dies on dsp1. If it is silent too, it dies on
# dsp2 at or before the mixer.
#
# usage:  sh deep-peek.sh [> /tmp/deep-peek.txt 2>&1]

set -u
POOL=/proc/hma/audio_buffer0/status
say() { echo "## $*"; }

full_nonzero() {
	a="$1"; sz="$2"
	kb=$(( sz / 1024 ))
	[ "$kb" -gt 0 ] || kb=1
	dd if=/dev/mem bs=1024 skip=$(( a / 1024 )) count="$kb" 2>/dev/null \
		| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c
}

say "starting tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 >/tmp/speaker-test.log 2>&1 &
st=$!
sleep 3

printf '  %-22s %-20s %9s %12s %s\n' NAME ADDR SIZE_KB NONZERO VERDICT
# Every bc-* buffer, scanned IN FULL. bc-sai0/1 are 64 KiB and bc-tp* 8 KiB,
# so the earlier 2 KiB sample said nothing about them either. output_speaker
# reports underflow-count=0 (it IS being fed) yet bc-speaker reads as zeros --
# so either the data is silence, or the speaker DAC is fed from a different
# chunk than the one named bc-speaker.
for want in alsa_playback mixerbin_04280001 \
            bc-speaker bc-hp bc-spdif bc-sai0 bc-sai1 bc-sai2 bc-tp0 bc-tp1 \
            bc-earc-s0 bc-earc-s1; do
	awk -v n="$want" '$NF == n { print $1, $2 }' "$POOL" 2>/dev/null | while read -r a s; do
		sz=$(( s ))
		nz=$(full_nonzero "$a" "$sz")
		if [ "$nz" -gt 2000 ]; then v="HAS AUDIO"; else v="silent-ish"; fi
		printf '  %-22s %-20s %9s %12s %s\n' "$want" "$a" "$(( sz / 1024 ))" "$nz" "$v"
	done
done

say "--- second pass 1 s later (changing content = live data) ---"
sleep 1
for want in mixerbin_04280001 bc-speaker; do
	awk -v n="$want" '$NF == n { print $1, $2 }' "$POOL" 2>/dev/null | while read -r a s; do
		printf '  %-22s %-20s %12s\n' "$want" "$a" "$(full_nonzero "$a" "$(( s ))")"
	done
done

kill $st 2>/dev/null; wait $st 2>/dev/null
say "0x86ad5000 is mixerbin.out2 -> dsp1; that one decides which DSP loses the signal"
