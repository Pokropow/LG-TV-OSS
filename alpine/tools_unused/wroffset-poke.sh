#!/bin/sh
# wroffset-poke.sh - is the DSP playback module's "wrOffset" property settable?
#
# What playback-probe.sh established, reading the module's OWN prop:
#     addr=0x86B15000   size=8192        <- SET_BUFFER landed correctly
#     rdOffset 4096 -> 7168 -> 6144      <- the DSP IS consuming, and wrapping
#     wrOffset=0x6040F368                <- a DSP-side pointer, CONSTANT across
#                                           all four rounds
# and _aplayback_updated fires every ~9.3 ms, so the "update" event works too.
# channels/bits-per-sample/rate all landed; those are set in aplayback_prepare,
# in process context. wrOffset is the only one set from aplayback_ack, which
# ALSA calls under the PCM stream lock with interrupts off.
#
# So: does the module accept the property at all? proc_inst_prop (module_list.c
# :854) takes two tokens and builds "%s=%s" itself, so the write is
#     wrOffset 4096       <- space, NOT wrOffset=4096
# and reading prop back reports the module's real value.
#
# PHASE 1 pokes once and reads back -> decides WHERE the break is.
# PHASE 2 chases rdOffset, doing from the shell what aplayback_ack should be
#         doing from the kernel: keep wrOffset half a ring ahead of rdOffset.
#         The ring is 8192 bytes = 2048 frames = ~42 ms at 48 kHz, so updating
#         every ~15 ms is enough to keep it fed.
#
# usage:  sh wroffset-poke.sh [> /tmp/wroffset-poke.txt 2>&1]
#         SECONDS_RUN=10 sh wroffset-poke.sh

set -u

P=/proc/aaudio/processors/dsp2/playback
SECONDS_RUN="${SECONDS_RUN:-6}"

say() { echo "## $*"; }
getprop() { sed -n "s/^ *$2=(int)\([-0-9]*\).*/\1/p" "$1/prop" 2>/dev/null | head -1; }

say "starting an endless tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 >/tmp/speaker-test.log 2>&1 &
st=$!

i=0
while [ $i -lt 40 ]; do
	set -- "$P"/*/
	[ -d "$1" ] && [ -e "$1/prop" ] && break
	i=$((i + 1))
	usleep 100000 2>/dev/null || sleep 1
done
set -- "$P"/*/
[ -d "$1" ] || { say "no playback instance"; cat /tmp/speaker-test.log; kill $st 2>/dev/null; exit 1; }
D="${1%/}"
say "instance $D"

SIZE=$(getprop "$D" size)
say "addr=$(getprop "$D" addr)  size=$SIZE"
[ -n "$SIZE" ] && [ "$SIZE" -gt 0 ] 2>/dev/null || { say "no usable size"; kill $st 2>/dev/null; exit 1; }

# ----------------------------------------------------------------- phase 1
say "===== PHASE 1: single poke ====="
say "wrOffset before : $(getprop "$D" wrOffset)"
say "rdOffset before : $(getprop "$D" rdOffset)"
echo "wrOffset 4096" > "$D/prop" 2>/dev/null || say "WARN write to prop failed"
usleep 200000 2>/dev/null || sleep 1
AFTER=$(getprop "$D" wrOffset)
say "wrOffset after  : $AFTER   (wrote 4096)"
say "rdOffset after  : $(getprop "$D" rdOffset)"

if [ "$AFTER" = "4096" ]; then
	say "RESULT: the module ACCEPTS wrOffset -> the property path works and"
	say "        the break is in the kernel's aplayback_ack delivery."
else
	say "RESULT: the module did NOT take wrOffset (still '$AFTER') -> the"
	say "        kernel is using the wrong mechanism, not just failing to"
	say "        deliver. Phase 2 will show nothing; that is informative."
fi

# ----------------------------------------------------------------- phase 2
say "===== PHASE 2: chase rdOffset for ${SECONDS_RUN}s ====="
say "(keeping wrOffset half a ring ahead -- what aplayback_ack should do)"
HALF=$((SIZE / 2))
n=0
LIMIT=$((SECONDS_RUN * 66))
moved=0
last=$(getprop "$D" rdOffset)
while [ $n -lt $LIMIT ]; do
	[ -e "$D/prop" ] || { say "instance went away after $n iterations"; break; }
	rd=$(getprop "$D" rdOffset)
	[ -n "$rd" ] || break
	[ "$rd" != "$last" ] && moved=$((moved + 1))
	last="$rd"
	echo "wrOffset $(( (rd + HALF) % SIZE ))" > "$D/prop" 2>/dev/null
	n=$((n + 1))
	[ $((n % 33)) = 0 ] && say "  t=$((n / 66))s rd=$rd wr=$(getprop "$D" wrOffset) fader=$(sed -n 's/^ *state=//p' /proc/aaudio/processors/dsp2/fader/*/prop 2>/dev/null | head -1)"
	usleep 15000 2>/dev/null || sleep 1
done
say "rdOffset changed $moved times over $n iterations"

say "===== final state ====="
sed 's/^/    /' "$D/prop" 2>/dev/null
say "fader:"
sed 's/^/    /' /proc/aaudio/processors/dsp2/fader/*/prop 2>/dev/null | grep -E 'state|queued-length|underflow'

kill $st 2>/dev/null
wait $st 2>/dev/null
say "speaker-test output"; cat /tmp/speaker-test.log
