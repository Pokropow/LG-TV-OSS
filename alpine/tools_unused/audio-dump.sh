#!/bin/sh
# audio-dump.sh - snapshot every live audio module instance while a PCM is open.
#
# Module instances exist only while the stream does, and each exposes
# status/lstatus (module_list.c:1120-1121). This grabs them all so the data
# path can be inspected after the fact.
#
# The open question it is meant to answer: the DSP playback module reports
#     playback_041d0001 ... playback_output_thread_callback: wrong read ptr 0x00000000
# and the fader reports "no input more than 50 ms", while the speaker output
# underflows with rd == wr -- i.e. nothing is flowing from the playback module
# at the head of the chain. The PCM ring is allocated from the "audio_buffer"
# HMA pool and its physical address is handed to the DSP in aplayback_prepare()
# via CAPTURE_CMD_SET_BUFFER (alsa_playback.c:504). If the DSP never got it,
# these status dumps are where it should show.
#
# usage:
#     WATCH=1 sh fader-bypass.sh &
#     speaker-test -D hw:0,0 -c 2 -t sine -l 0 &
#     sh audio-dump.sh > /tmp/audio-dump.txt
#     kill %2 %1

set -u

P=/proc/aaudio
OUT="${OUT:-/dev/stdout}"

sect() { echo; echo "===== $* ====="; }

sect "uname / card"
uname -a
cat /proc/asound/cards 2>/dev/null

sect "live instances (symlinks, module_list.c:1126)"
ls -l $P/instances/ 2>/dev/null || echo "(none)"

sect "registered implementations per processor"
for p in $P/processors/*/; do
	[ -d "$p" ] || continue
	echo "-- $(basename "$p"): $(ls "$p" | tr '\n' ' ')"
done

sect "instance status / lstatus"
for p in $P/processors/*/; do
	for m in "$p"*/; do
		[ -d "$m" ] || continue
		for i in "$m"*/; do
			[ -d "$i" ] || continue
			[ -e "$i/status" ] || continue
			echo
			echo "--- $(echo "$i" | sed "s|$P/processors/||")"
			cat "$i/status" 2>/dev/null
			[ -e "$i/lstatus" ] && { echo "  -- lstatus:"; cat "$i/lstatus" 2>/dev/null; }
			[ -e "$i/prop" ] && { echo "  -- prop:"; cat "$i/prop" 2>/dev/null; }
		done
	done
done

sect "module connection graph"
cat $P/dump_module_connection 2>/dev/null || echo "(unreadable)"

sect "aaudio top-level"
for f in instances roles register; do
	echo "--- $f"
	cat $P/$f 2>/dev/null | head -40
done

sect "fwload mcu status"
for n in 0 1 2 3; do cat /proc/mcu/aud$n/status 2>/dev/null; done

sect "HMA pool for the PCM ring"
echo "aplayback_poolname = $(cat /sys/module/lg1k/parameters/aplayback_poolname 2>/dev/null || echo '?')"
grep -i 'reserved CMA area\|audio_buffer' /proc/iomem 2>/dev/null | head

sect "sndout + amixer snapshot"
cat $P/seetv/sndout 2>/dev/null | head -60
cat $P/seetv/amixer 2>/dev/null | head -40
