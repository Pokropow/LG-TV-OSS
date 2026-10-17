#!/bin/sh
# prop-control.sh - does ANY prop write reach the DSP playback module, and does
# it accept wrOffset?
#
# Everything so far has been ambiguous because we never established a control:
# "wrOffset did not change" could mean the module rejects it OR that no prop
# write lands at all. This settles both with one run.
#
# From the dsp2 firmware's own string table (audio_a0_dsp2.bin):
#     playback_set_wrOffset          <- the module HAS a wrOffset setter
#     playback_prop_updated          <- its property-change handler
#     "%s: updated %s=%d"            <- it LOGS every property it accepts
#     "wrOffset(0x%x) == rdOffset(0x%x), buf_full = TRUE"
#     "need more data. wait.. wrOffset %x, rdOffset %x read_size %d."
#
# Note that last pair: in THIS module wr == rd means the ring is FULL, not
# empty -- the inverse of the usual convention, and the inverse of what the
# parked patch assumed when it held back a frame to keep them unequal.
#
# The "updated" line is logged below the instance's default log-mask of 7, so
# step 1 raises the mask. If the mask readback changes, prop writes work and
# the control is established; then whether wrOffset changes is conclusive.
#
# usage:  sh prop-control.sh [> /tmp/prop-control.txt 2>&1]

set -u
P=/proc/aaudio/processors/dsp2/playback
say() { echo "## $*"; }
getprop() { sed -n "s/^ *$2=(int)\([-0-9]*\).*/\1/p" "$1/prop" 2>/dev/null | head -1; }

say "starting an endless tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 >/tmp/speaker-test.log 2>&1 &
st=$!

i=0
while [ $i -lt 40 ]; do
	set -- "$P"/*/
	[ -d "$1" ] && [ -e "$1/prop" ] && break
	i=$((i + 1)); usleep 100000 2>/dev/null || sleep 1
done
set -- "$P"/*/
[ -d "$1" ] || { say "no playback instance"; cat /tmp/speaker-test.log; kill $st 2>/dev/null; exit 1; }
D="${1%/}"
say "instance $D"

# ---------------------------------------------------- 1. CONTROL: log-mask
say "===== CONTROL: is any prop write honoured? ====="
say "log-mask before : $(getprop "$D" log-mask)"
echo "log-mask 4294967295" > "$D/prop" 2>/dev/null || say "WARN prop write returned an error"
usleep 300000 2>/dev/null || sleep 1
LM=$(getprop "$D" log-mask)
say "log-mask after  : $LM   (wrote 4294967295)"
if [ "$LM" = "4294967295" ] || [ "$LM" = "-1" ]; then
	say "CONTROL PASSES: prop writes DO reach the module."
else
	say "CONTROL FAILS: not even log-mask changed, so no prop write lands."
	say "  -> wrOffset never had a chance; the kernel's whole set-property"
	say "     route to this module is the thing to fix."
fi

# ---------------------------------------------------- 2. the real question
say "===== wrOffset, with the module now verbose ====="
say "wrOffset before : $(getprop "$D" wrOffset)"
say "rdOffset before : $(getprop "$D" rdOffset)"
echo "wrOffset 4096" > "$D/prop" 2>/dev/null
usleep 300000 2>/dev/null || sleep 1
say "wrOffset after  : $(getprop "$D" wrOffset)   (wrote 4096)"
say "rdOffset after  : $(getprop "$D" rdOffset)"

say "===== what the DSP said (looking for 'updated <name>=') ====="
dmesg | grep -aE 'updated |playback_041|buf_full|need more data|no data. wait|wrong read ptr' \
      | tail -40 | sed 's/^/  /'

say "===== final prop ====="
sed 's/^/    /' "$D/prop" 2>/dev/null

kill $st 2>/dev/null; wait $st 2>/dev/null
say "speaker-test:"; tail -3 /tmp/speaker-test.log
