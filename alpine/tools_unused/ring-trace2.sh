#!/bin/sh
# ring-trace2.sh - kernel ring state and DSP ring state, same timeline.
#
# Every previous capture showed one side only, and each time the other side
# contradicted the conclusion:
#   - kernel rdOffset stuck at 0      -> "DSP consumes nothing"   (it does)
#   - prop wrOffset a constant ptr    -> "wrOffset never arrives" (it does;
#                                         the prop READ is stale heap data)
#   - rd overshooting a -4 wr         -> "rd laps the writer"     (but the DSP
#                                         drains at ~1/11 real time, so it
#                                         cannot outrun the writer)
#
# So capture both. The levels matter: aplayback 'info' gets ack (noti),
# prepare and trigger, WITHOUT _aplayback_updated's debug/trace, which
# previously flooded 1235 lines and evicted everything else from dmesg.
# DSP mask 31 = error|warning|noti|info|debug -- process_buf is DEB -- but not
# trace.
#
# What to read off the result: for each kernel ack, wrOffset/sw_ptr/hw_avail
# and the kernel's rdOffset; for each DSP process_buf, wr/rd. If ALSA declares
# XRUN while the DSP is still waiting for data, the two sides disagree about
# the pointers and the disagreement is the bug.
#
# usage:  sh ring-trace2.sh [> /tmp/ring-trace2.txt 2>&1]

set -u
P=/proc/aaudio/processors/dsp2/playback
say() { echo "## $*"; }

# NOTE: with patch 0007 the tree is back to PRISTINE alsa_playback.c, where
# aplayback_ack logs at debug() -- the parked patch's noti() version is gone.
# So 'info' would capture no ack lines at all. 'debug' also turns on
# _aplayback_updated's "got callback from" (~one per 5.33 ms), hence the
# shorter capture window below.
# trace, not debug: the only way to see whether each "update" event carries a
# payload is _aplayback_updated's trace("rdOffset is 0x%08x"), which sits
# inside `if (_param && _paramLen)`. Without a payload rdOffset is never
# assigned and snd_pcm_period_elapsed() is never called -- which would explain
# aplayback_pointer being invoked only twice for 28 update callbacks.
# This was unaffordable while the DSP free-ran (1235 events); with 0007+0008
# pacing it correctly there are ~28, so trace fits in the log buffer.
say "aplayback -> trace (ack + prepare + trigger + rdOffset payloads)"
echo 'aplayback:trace' > /proc/logm/status 2>/dev/null || say "WARN logm write failed"

say "starting tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 >/tmp/speaker-test.log 2>&1 &
st=$!
i=0
while [ $i -lt 40 ]; do
	set -- "$P"/*/
	[ -d "$1" ] && [ -e "$1/prop" ] && break
	i=$((i + 1)); usleep 100000 2>/dev/null || sleep 1
done
set -- "$P"/*/
[ -d "$1" ] || { say "no instance"; kill $st 2>/dev/null; exit 1; }
D="${1%/}"
say "instance $D"

# 31 = err|warn|noti|info|debug, no trace
echo "log-mask 31" > "$D/prop" 2>/dev/null
usleep 200000 2>/dev/null || sleep 1

dmesg -c >/dev/null 2>&1
sleep 1
kill $st 2>/dev/null; wait $st 2>/dev/null

say "===== interleaved, in kernel-time order ====="
dmesg | grep -aE 'aplayback|process_buf|no data. wait|need more data|playback_041|XRUN|xrun' \
      | sed -e 's/aud_kaimc.*aud2  *610: */DSP  /' \
            -e 's/aplayback  */KRN  /' \
      | sed 's/^/  /'

say "===== counts ====="
for k in 'no data. wait' 'process_buf' 'got callback from' 'rdOffset is' 'aplayback_pointer' 'aplayback_trigger'; do
	printf '  %-20s %s\n' "$k" "$(dmesg | grep -ac "$k")"
done
say "speaker-test: $(grep -c 'Broken pipe' /tmp/speaker-test.log) EPIPE"
tail -3 /tmp/speaker-test.log | sed 's/^/  /'

echo 'aplayback:noti' > /proc/logm/status 2>/dev/null
