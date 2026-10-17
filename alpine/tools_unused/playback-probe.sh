#!/bin/sh
# playback-probe.sh - read the DSP playback module's OWN view of the ring.
#
# The kernel side of the protocol is now understood and verified:
#   aimc_module_create("playback", -1)                      -> uid 0x041d000N
#   aimc_register_named_event(... "update", true)            <- DSP should send rdOffset
#   aimc_set_property(uid, "channels/bits-per-sample/rate")
#   CAPTURE_CMD_SET_BUFFER {buf_addr_p, buf_size}            (only 2 commands exist;
#   CAPTURE_CMD_RESET_BUFFER                                  there is NO start command)
#   aimc_set_property(uid, "wrOffset=%d")  on every ack
#
# Ruled out already: the buffer address (0x86b15000, inside audio_buffer0 next to
# aud0_ram..aud3_ram, so no 32-bit truncation of buf_addr_p) and the DSP's
# "wrong read ptr 0x00000000", which is logged ~39 ms BEFORE SET_BUFFER arrives.
#
# What is left to check is whether the property actually reaches the module.
# Reading an instance's 'prop' reports the module's real property values
# (module_list.c:1119, same file that makes cmd/status/lstatus), so if
# "wrOffset" is absent from the playback instance's prop, or present but stuck,
# that localises the break to the property plumbing rather than the ring.
#
# usage:  sh playback-probe.sh [> /tmp/playback-probe.txt 2>&1]
#         ROUNDS=6 sh playback-probe.sh

set -u

P=/proc/aaudio/processors
ROUNDS="${ROUNDS:-4}"
MODS="${MODS:-dsp2/playback dsp2/pcmcvt dsp2/sola dsp2/lipsync dsp2/mixer dsp2/mixerbin dsp2/fader dsp1/output_speaker}"

say() { echo "## $*"; }

say "raising aplayback log level"
echo 'aplayback:debug' > /proc/logm/status 2>/dev/null || say "WARN could not set logm level"

# -b/-p: the DEFAULT 2048-frame buffer is 42.6 ms, far shorter than the
# kernel<->DSP IPC latency (~hundreds of ms, measured), so it always underran
# before the next pointer update landed. ~680 ms absorbs that and the stream
# now runs with no EPIPE at all.
say "starting an endless tone in the background (680 ms buffer)"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 >/tmp/speaker-test.log 2>&1 &
st=$!

# The instance appears at PCM open and vanishes at close, so wait for it.
i=0
while [ $i -lt 40 ]; do
	set -- "$P"/dsp2/playback/*/
	[ -d "$1" ] && break
	i=$((i + 1))
	usleep 100000 2>/dev/null || sleep 1
done

set -- "$P"/dsp2/playback/*/
if [ ! -d "$1" ]; then
	say "no playback instance appeared -- speaker-test output:"
	cat /tmp/speaker-test.log
	kill $st 2>/dev/null
	exit 1
fi
say "playback instance: $1"

r=0
while [ "$r" -lt "$ROUNDS" ]; do
	r=$((r + 1))
	echo
	say "===== round $r ====="
	for m in $MODS; do
		for d in "$P/$m"/*/; do
			[ -d "$d" ] || continue
			[ -e "$d/prop" ] || continue
			echo "--- $m/$(basename "$d")"
			echo "  prop:"
			sed 's/^/    /' "$d/prop" 2>/dev/null
			echo "  status:"
			sed 's/^/    /' "$d/status" 2>/dev/null
			[ -e "$d/lstatus" ] && { echo "  lstatus:"; sed 's/^/    /' "$d/lstatus" 2>/dev/null; }
		done
	done
	usleep 400000 2>/dev/null || sleep 1
done

echo
say "speaker-test output"
kill $st 2>/dev/null
wait $st 2>/dev/null
cat /tmp/speaker-test.log

echo
say "driver's own sndout / amixer dumps"
sed 's/^/  /' /proc/aaudio/seetv/sndout 2>/dev/null | head -60
say "--- hardware output buffers (does anything reach the DAC?) ---"
dmesg | grep -aE 'underflow|output_speaker|irq_handle_bc|alsasndout' | tail -20 | sed 's/^/  /'

say "aplayback ack/pointer lines from dmesg"
dmesg | grep -aE 'aplayback|playback_041|rdOffset|wrOffset' | tail -40
