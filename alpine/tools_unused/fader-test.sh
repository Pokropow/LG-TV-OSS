#!/bin/sh
# fader-test.sh - is a fader zeroing the stream?
#
# Established: the alsa_playback ring holds a real sine (~2022 non-zero), every
# output buffer (bc-speaker/bc-hp/bc-spdif) is exactly 0, and the mixerbin
# buffers are at the ~33 "empty chunk" baseline. So the chain moves the right
# byte counts and carries silence, and it is already silent by the mixer.
#
# The fader is the module whose documented job is to emit zeros:
#   _fader_process_data_fadeout. 789: send zero data...
# and chain-trace caught "yield before fadeout.. queued 0" on dsp1's queue
# instance. Both faders expose a writable "bypass" property
# (mixer.c:737 mixer_set_bypass_fader -> prop "bypass"); proc_inst_prop takes
# two tokens and builds "%s=%s" itself, so the write is `bypass 1`, with a
# SPACE, not `bypass=1`.
#
# Measures bc-speaker before and after the bypass, so the answer is a number
# rather than an impression.
#
# usage:  sh fader-test.sh [> /tmp/fader-test.txt 2>&1]

set -u
P=/proc/aaudio/processors
POOL=/proc/hma/audio_buffer0/status
say() { echo "## $*"; }

spk_nonzero() {
	a=$(awk '$NF == "bc-speaker" { print $1; exit }' "$POOL" 2>/dev/null)
	[ -n "$a" ] || { echo "?"; return; }
	dd if=/dev/mem bs=1024 skip=$(( a / 1024 )) count=2 2>/dev/null \
		| od -A n -t x1 | tr -d ' \n' | sed 's/00//g' | wc -c
}

say "starting tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 >/tmp/speaker-test.log 2>&1 &
st=$!
sleep 2

say "bc-speaker non-zero BEFORE: $(spk_nonzero)   (1 == pure silence)"

say "--- fader states before ---"
for m in dsp2/fader dsp1/queue dsp2/gain dsp1/outctrlbin; do
	for d in "$P/$m"/*/; do
		[ -e "$d/prop" ] || continue
		echo "  $m/$(basename "$d"): $(sed -n 's/^ *state=//p;s/^ *bypass=(bool)//p' "$d/prop" 2>/dev/null | tr '\n' ' ')"
	done
done

n=0
for m in dsp2/fader dsp1/queue; do
	for d in "$P/$m"/*/; do
		[ -e "$d/prop" ] || continue
		if echo "bypass 1" > "$d/prop" 2>/dev/null; then
			say "bypassed $m/$(basename "$d")"
			n=$((n + 1))
		fi
	done
done
say "bypassed $n fader instance(s)"
sleep 2

say "bc-speaker non-zero AFTER:  $(spk_nonzero)"

say "--- fader states after ---"
for m in dsp2/fader dsp1/queue; do
	for d in "$P/$m"/*/; do
		[ -e "$d/prop" ] || continue
		echo "  $m/$(basename "$d"):"
		grep -aE 'state=|bypass=|queued-length=|underflow' "$d/prop" 2>/dev/null | sed 's/^/      /'
	done
done

kill $st 2>/dev/null; wait $st 2>/dev/null
say "if AFTER is large, a fader was zeroing the stream"
