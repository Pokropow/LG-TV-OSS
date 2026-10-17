#!/bin/sh
# pcm-peek.sh - are the samples reaching the DAC actually audio, or zeros?
#
# Where we are: the DSP chain runs end to end. chain-trace.sh showed
#   playback process_buf -> fader push data -> dap_write_pcm 2048 bytes
#   -> output_speaker out_chain_bc: data size 0x800, rd/wr ping-ponging
# so the hardware buffer is being written and the DMA is consuming it, with no
# EPIPE. Yet there is no sound -- and buzzing WAS audible on the webOS 23/25
# kernels, so the amplifier is capable of making noise.
#
# That leaves two possibilities, and reading the buffer separates them:
#   bytes are a sine wave -> the SoC is emitting real audio; the fault is
#                            after the DAC (routing, amp enable, I2S format)
#   bytes are all zero    -> the chain moves the right NUMBER of bytes but the
#                            content is silence; something upstream (SE/DAP,
#                            mixer input gain/mute) is zeroing it
#
# CONFIG_STRICT_DEVMEM is not set in lg1k_defconfig, so /dev/mem can read the
# reserved HMA regions directly. Addresses come from the pool status rather
# than being hardcoded, since they can move.
#
# usage:  sh pcm-peek.sh            (run while a tone is playing)
#         sh pcm-peek.sh --tone     (start its own tone first)

set -u
say() { echo "## $*"; }

POOL=/proc/hma/audio_buffer0/status
[ -r "$POOL" ] || POOL=/proc/hma/audio_buffer/status
[ -r "$POOL" ] || { say "no HMA pool status; is lg1k loaded?"; exit 1; }

if [ "${1:-}" = "--tone" ]; then
	say "starting tone"
	speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 >/tmp/speaker-test.log 2>&1 &
	st=$!
	sleep 2
else
	st=""
fi

peek() {
	name="$1"
	# status lines are TAB separated: "<addr>\t<size>\tused\t<name>".
	# Matching on a leading space missed every one of them.
	line=$(awk -v n="$name" '$NF == n { print; exit }' "$POOL" 2>/dev/null)
	[ -n "$line" ] || {
		say "$name: not found. Pool contains:"
		awk '{print "      " $NF}' "$POOL" 2>/dev/null | sort -u | tr '\n' ' '
		echo
		return
	}
	addr=$(echo "$line" | awk '{print $1}')
	size=$(echo "$line" | awk '{print $2}')
	say "$name at $addr size $size"

	# /dev/mem, 1 KiB units -- every HMA chunk here is 1 KiB aligned
	off=$(( addr / 1024 ))
	for pass in 1 2; do
		echo "    pass $pass:"
		dd if=/dev/mem bs=1024 skip="$off" count=1 2>/dev/null \
			| od -A x -t x2 | head -6 | sed 's/^/      /'
		nz=$(dd if=/dev/mem bs=1024 skip="$off" count=2 2>/dev/null \
			| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c)
		echo "      non-zero nibbles in 2 KiB: $nz"
		[ "$pass" = 1 ] && { usleep 300000 2>/dev/null || sleep 1; }
	done
}

# --- scan mode: which chunks in the pool hold audio, and which hold silence?
# bc-speaker is all zeros while the alsa_playback ring holds a clean sine, so
# the chain carries the right byte COUNT and no signal. The module-to-module
# buffers live in this same pool (mixerbin_*, aud*_ram, ipc-*), so sampling
# every chunk localises exactly where the audio stops.
if [ "${SCAN:-0}" = 1 ] || [ "${1:-}" = "--scan" ] || [ "${2:-}" = "--scan" ]; then
	say "===== scanning every chunk in $POOL ====="
	printf '  %-22s %-20s %10s %s\n' NAME ADDR NONZERO STATE
	awk '{print $1, $3, $NF}' "$POOL" 2>/dev/null | while read -r a cstate nm; do
		o=$(( a / 1024 ))
		nz=$(dd if=/dev/mem bs=1024 skip="$o" count=2 2>/dev/null \
			| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c)
		printf '  %-22s %-20s %10s %s\n' "$nm" "$a" "$nz" "$cstate"
	done
	say "(NONZERO is a rough count over the first 2 KiB; ~1 means all zeros)"
	[ -n "$st" ] && { kill $st 2>/dev/null; wait $st 2>/dev/null; }
	exit 0
fi

say "===== speaker hardware buffer (what the DAC reads) ====="
peek bc-speaker
say "===== headphone hardware buffer, for comparison ====="
peek bc-hp
say "===== the ALSA ring userspace wrote into ====="
peek alsa_playback

[ -n "$st" ] && { kill $st 2>/dev/null; wait $st 2>/dev/null; }
say "done -- identical bytes across both passes means the buffer is static"
