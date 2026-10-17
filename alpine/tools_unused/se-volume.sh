#!/bin/sh
# se-volume.sh - the SE's OSD volume is zero on ours and non-zero on stock.
#
# THE FINDING. Reading each dsp1 instance's lstatus (never collected before --
# audio-snapshot.sh only ever took prop) gives live sample values and internal
# state. The dap is working:
#
#   = multch input sample value
#   = L  :0xb9600000, R :0x       0, ...        <- real input
#   = 2ch output sample value
#   = L  :0xcd197b00, R :0xfffd0200,            <- real OUTPUT
#
# and the se passes the byte count straight through
# (inbyte/outbyte 347330560/347330560). But:
#
#   ours    = OSD Volume Gain  : 0x00000000     = OSD Volume Index : 0x00000000
#   stock   = OSD Volume Gain  : 0x00007004     = OSD Volume Index : 0x00176d37
#
# A volume of zero explains every observation at once: real audio into dsp1,
# the dap producing real output, correct byte counts and cadence everywhere
# downstream, zero underflows -- and perfectly-sized blocks of silence landing
# in bc-speaker.
#
# (The se's own input/output sample values read 0x0 on BOTH boxes, so those
# fields are simply not populated in bypass mode. Not evidence of anything.)
#
# THE CONTROL. core/audio/alsa/alsa_se.c:1089 registers "LGSE Var Fn009" at
# index 0 for LX_AUD_MASTER_SE_ID_0 (the speaker), payload LGSE_VAR_FN009_NUM
# = 2 * 4 bytes, and alsa_se.c:960 confirms the layout:
#
#   noti ("Fn009_Var(OSD Volume): SE_ID=%d, Index=%d, Gain=0x%X, UI Vol=%d",
#         se_id, param_index, vol[0], vol[1]);
#
# so vol[0] = gain, vol[1] = UI volume. We write STOCK'S OWN OBSERVED VALUES
# rather than inventing any: 0x00007004 and 0x00176d37, little-endian.
#
# Keep the TV at a moderate volume before running this: it is stock's normal
# operating level, not a boosted one, but it is the first time this path has
# carried signal.
#
# usage:  sh se-volume.sh [> /tmp/se-volume.txt 2>&1]
#         GAIN=0x7004 UIVOL=0x176d37 sh se-volume.sh

set -u
P=/proc/aaudio/processors
CTL='LGSE Var Fn009'
GAIN="${GAIN:-0x7004}"
UIVOL="${UIVOL:-0x176d37}"
say() { echo "## $*"; }

# little-endian byte list for a 32-bit value
le32() { v=$(( $1 )); echo "$(( v & 255 )),$(( (v >> 8) & 255 )),$(( (v >> 16) & 255 )),$(( (v >> 24) & 255 ))"; }
BYTES="$(le32 "$GAIN"),$(le32 "$UIVOL")"

say "target: gain=$GAIN uivol=$UIVOL  -> bytes $BYTES"

say "===== the control, as the driver registered it ====="
say "(amixer enumeration aborts early on this driver, so address BY NAME)"
amixer -c 0 cget name="$CTL" 2>&1 | sed 's/^/     /'

selstatus() {
	for d in "$P"/dsp1/se/*/ "$P"/dsp1/dap/*/; do
		[ -r "$d/lstatus" ] || continue
		echo "     --- ${d#$P/}"
		grep -aE 'OSD Volume|sample value|L  :|R  :|inbyte' "$d/lstatus" 2>/dev/null \
			| sed 's/^/       /'
	done
}
bcnz() {
	awk '$NF == "bc-speaker" { print $1, $2; exit }' /proc/hma/audio_buffer0/status \
	| while read -r a s; do
		dd if=/dev/mem bs=512 skip=$(( a / 512 )) count=$(( s / 512 )) 2>/dev/null \
			| od -A n -t x4 -v | tr -s ' ' '\n' | grep -c '[1-9a-f]'
	done
}

say "starting tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 \
	>/tmp/speaker-test.log 2>&1 &
st=$!
sleep 3

say "===== BEFORE ====="
say "bc-speaker non-zero words: $(bcnz) / 2048"
selstatus

say "===== writing $CTL ====="
# BYTES controls take a comma-separated byte list. Try the plain form first,
# then with an explicit index, then hex -- amixer's accepted syntax for byte
# arrays varies by version, and a silent failure here would look exactly like
# "the theory is wrong", so every attempt is printed.
ok=0
for attempt in \
	"amixer -c 0 cset name='$CTL' $BYTES" \
	"amixer -c 0 cset name='$CTL',index=0 $BYTES" \
	"amixer -c 0 -- cset name='$CTL' $BYTES"
do
	say "try: $attempt"
	if out=$(eval "$attempt" 2>&1); then
		echo "$out" | sed 's/^/     /'
		ok=1
		break
	fi
	echo "$out" | sed 's/^/     FAILED: /'
done
[ "$ok" = 1 ] || say "!!! every amixer form failed -- see dmesg for the driver's view"

say "===== driver's own log line (proves the put reached it) ====="
dmesg | grep -a 'Fn009_Var' | tail -3 | sed 's/^/     /'
say "(no line here means the write never reached _se_func_put)"

sleep 2
say "===== AFTER ====="
say "bc-speaker non-zero words: $(bcnz) / 2048"
selstatus

kill $st 2>/dev/null; wait $st 2>/dev/null
say ""
say "bc-speaker going from 0 to ~1024/2048 means this was it."
