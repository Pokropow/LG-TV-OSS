#!/bin/sh
# chain-trace.sh - why does data stop between playback and the speaker output?
#
# STATUS (2026-10-17): AUDIO WORKS. The cause was the SE's OSD volume sitting
# at zero -- `audio-up.sh` now writes "LGSE Var Fn009". Everything below this
# line was written while it was still broken, so its "state of play" is
# history, not current fact. The tool itself is still good for debugging.
#
# State of play: the ring protocol works (no EPIPE with a ~680 ms buffer) and
# the playback module has a valid buffer (addr 0x86B15000, size 130560). But:
#
#   playback rdOffset : 18432 -> 20480 -> 22528   (2048 B per ~400 ms = ~5 KB/s;
#                                                  real time needs 192 KB/s)
#   fader             : queued-length 0, state=wait, underflow-count climbing
#   output_speaker    : queued-length 0, underflow-count 0  (never fed at all)
#
# So playback is being consumed far below real time and almost nothing reaches
# the mixer. Either playback cannot push (downstream backpressure) or it is not
# being told there is data (wrOffset not advancing). Only the DSP-side logs of
# the WHOLE chain can tell those apart, so raise log-mask on every live
# instance, not just playback.
#
# 31 = error|warning|noti|info|debug (no trace). The interesting lines:
#   playback  process_buf: wr 0x... rd 0x... data->size ...
#   playback  "no data. wait.." / "need more data"
#   pcmcvt    Pcmcvt_Event: first event / got first event
#   fader     _fader_process_data_fadeout "send zero data"
#             _fader_process_data_wait "raise underflow event"
#   mix_lg    lgmix_event_first
#
# usage:  sh chain-trace.sh [> /tmp/chain-trace.txt 2>&1]

set -u
P=/proc/aaudio/processors
say() { echo "## $*"; }

say "starting tone (680 ms buffer -- the size that stopped the EPIPEs)"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 >/tmp/speaker-test.log 2>&1 &
st=$!

# wait for the playback instance, then make the whole chain verbose
i=0
while [ $i -lt 40 ]; do
	set -- "$P"/dsp2/playback/*/
	[ -d "$1" ] && [ -e "$1/prop" ] && break
	i=$((i + 1)); usleep 100000 2>/dev/null || sleep 1
done

# Only the modules on the playback path. Raising log-mask on all 27 live
# instances wedged the box: with ignore_loglevel on the cmdline every printk is
# clocked out of ttyAMA0 at 115200 baud (~10 ms a line) and the kernel blocks
# on it. Boot with loglevel=4 instead of ignore_loglevel -- dmesg still records
# everything, the UART just stops being the bottleneck.
# dsp1/dap MUST be here: stock logs "dap_chain. 833: input 8192. all 8192"
# every cycle, and ours has never logged dap_chain at all -- but dap was
# missing from this list, so its log-mask was never raised and the absence
# proved nothing. With it raised, "dap_chain" present-or-absent is decisive.
CHAIN="${CHAIN:-dsp1/gluepr dsp1/bypass dsp1/dap dsp1/se dsp1/queue dsp1/outctrlbin dsp1/output_speaker dsp2/mixerbin}"
n=0
for m in $CHAIN; do
	for d in "$P/$m"/*/; do
		[ -d "$d" ] || continue
		[ -e "$d/prop" ] || continue
		echo "log-mask 31" > "$d/prop" 2>/dev/null && n=$((n + 1))
	done
done
say "raised log-mask on $n instances ($CHAIN)"
say "live chain: $(ls -d "$P"/dsp*/*/*/ 2>/dev/null | sed 's|.*/processors/||;s|/[0-9a-f]*/$||' | sort -u | tr '\n' ' ')"

usleep 200000 2>/dev/null || sleep 1
dmesg -c >/dev/null 2>&1
sleep 2
kill $st 2>/dev/null; wait $st 2>/dev/null

say "===== DSP chain, in order ====="
dmesg | grep -aE 'process_buf|no data|need more data|Pcmcvt|fader|lgmix|mixerbin|output|underflow|sola|lipsync|glue|se_03|queue_03|bypass_03|out_chain|push data|write_pcm|dap_chain' \
      | sed -e 's/.*aud_kaimc.*aud[0-9]  *[0-9]*: *[0-9.]*\] */DSP /' \
      | sed 's/^/  /' | head -60

say "===== counts ====="
for k in 'dap_chain' 'dap_write_pcm' 'push data' 'out_chain_bc' 'underflow' 'glue'; do
	printf '  %-20s %s\n' "$k" "$(dmesg | grep -ac "$k")"
done
say "speaker-test: $(grep -c 'Broken pipe' /tmp/speaker-test.log) EPIPE"
