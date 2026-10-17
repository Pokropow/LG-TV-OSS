#!/bin/sh
# se-mode-test.sh - is the Dolby DAP turning the stream into silence?
#
# Established: alsa_playback holds a real sine, bc-speaker is pure zeros, the
# mixerbin buffers are at the empty baseline, and bypassing both faders changed
# nothing. dsp1's dap_write_pcm reports 2048 bytes per cycle into a destination
# that stays zero, so the silence is generated in the SE/DAP stage.
#
# Our bring-up sets (alsa-ext-soundengine-common.h):
#   LGSE SoundEngine Init 5 = LGSE_INIT_LGSE_ATMOS_AISOUND  (LGSE + DAP + AI Sound)
#   LGSE SoundEngine Mode 3 = LGSE_MODE_LGSE_ATMOS          (use DAP)
# i.e. everything goes through Dolby DAP and AI Sound -- which on stock are
# configured by userspace via ~61 "LGSE ..." parameter controls that we have
# never written. An untuned DAP emitting zeros fits every symptom.
#
# With Init 5, that header documents MODE_LGSE_ONLY (1) and MODE_LGSE_ATMOS (3)
# as valid and VX (2) / AISOUND (4) as errors, so mode 1 can be selected live.
#
# usage:  sh se-mode-test.sh [> /tmp/se-mode-test.txt 2>&1]

set -u
CARD="${CARD:-0}"
POOL=/proc/hma/audio_buffer0/status
say() { echo "## $*"; }

spk() {
	a=$(awk '$NF == "bc-speaker" { print $1; exit }' "$POOL" 2>/dev/null)
	[ -n "$a" ] || { echo "?"; return; }
	dd if=/dev/mem bs=1024 skip=$(( a / 1024 )) count=2 2>/dev/null \
		| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c
}

say "starting tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 >/tmp/speaker-test.log 2>&1 &
st=$!
sleep 2

for m in 3 1 0; do
	case $m in
		3) n="LGSE_ATMOS (DAP) -- current" ;;
		1) n="LGSE_ONLY (no DAP, no AI Sound)" ;;
		0) n="UNKNOWN/uninitialised" ;;
	esac
	say "----- Mode $m: $n -----"
	if amixer -c "$CARD" cset name='LGSE SoundEngine Mode' "$m" >/dev/null 2>&1; then
		sleep 2
		say "  readback  : $(amixer -c "$CARD" cget name='LGSE SoundEngine Mode' 2>/dev/null | sed -n 's/^ *: values=//p')"
		say "  bc-speaker: $(spk)      (1 == pure silence)"
	else
		say "  cset rejected this mode"
	fi
done

say "----- restoring mode 3 -----"
amixer -c "$CARD" cset name='LGSE SoundEngine Mode' 3 >/dev/null 2>&1
kill $st 2>/dev/null; wait $st 2>/dev/null
say "a large bc-speaker count on any mode means the SE stage was the blocker"
