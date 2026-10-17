#!/bin/sh
# stock-audio-probe.sh - capture how audio actually works on STOCK webOS.
#
# READ-ONLY. It only reads files and lists processes; it never writes a proc
# file, never sets a control, never touches the DSPs. Safe to run on a working
# TV while audio is playing.
#
# The questions it is meant to answer, in priority order:
#
#  1. Does stock EVER instantiate the `playback` module on dsp2 -- i.e. does
#     anything use the ALSA PCM path we spent so long on? If it never appears,
#     that path is dead code in practice and the AAPI chardev is the only route.
#  2. If it does appear, what do its ring values look like while WORKING?
#     addr/size/rdOffset/wrOffset from a functioning stream is the single most
#     valuable artifact we could get.
#  3. Which process drives audio, and through which device node -- /dev/snd/*
#     (ALSA) or the `audio` chardev (AAPI)?
#  4. What does fwload_audio2 do? It is what starts the DSP cores on stock and
#     is not in the GPL tree.
#
# usage, on stock, as root:
#     sh stock-audio-probe.sh > /tmp/stock-audio.txt 2>&1
#
# Run it TWICE and keep both files:
#     (a) on a normal TV channel or HDMI input  -> the adec path in use
#     (b) while playing a local music/video file from USB, or with UI click
#         sounds happening -> most likely to exercise the PCM path

sect() { echo; echo "===== $* ====="; }

sect "uname / build"
uname -a
cat /proc/version

sect "the script that starts the DSP cores (not in the GPL tree)"
for n in fwload_audio2 fwloader audpera; do
	p=$(command -v $n 2>/dev/null)
	echo "--- $n -> ${p:-not found}"
	[ -n "$p" ] && file "$p" 2>/dev/null
	# only cat it if it is a text script, never a binary
	[ -n "$p" ] && head -c 2 "$p" 2>/dev/null | grep -q '#!' && { echo "    (script, contents:)"; sed 's/^/    /' "$p"; }
done

sect "firmware_audio.sh (for reference / diffing against ours)"
cat /etc/systemd/system/scripts/firmware_audio.sh 2>/dev/null

sect "how stock staged the DSP firmware"
for n in 0 1 2 3; do cat /proc/mcu/aud$n/status 2>/dev/null; done
echo "--- audio_lnx (o24-only, may be absent) ---"
cat /proc/mcu/audio_lnx/status 2>/dev/null

sect "ALSA cards / pcm devices"
cat /proc/asound/cards 2>/dev/null
echo "--- pcm list ---"
cat /proc/asound/pcm 2>/dev/null

sect "which PCM substreams are OPEN/RUNNING right now"
for f in /proc/asound/card*/pcm*/sub*/status; do
	[ -f "$f" ] || continue
	st=$(head -1 "$f" 2>/dev/null)
	[ "$st" = "closed" ] && continue
	echo "--- $f"
	cat "$f"
done

sect "who holds audio device nodes"
echo "--- /dev/snd ---"
ls -l /dev/snd/ 2>/dev/null
echo "--- the AAPI 'audio' chardev(s) ---"
ls -l /dev/audio* /dev/aud* 2>/dev/null
echo "--- processes with an audio fd open ---"
for p in /proc/[0-9]*; do
	ls -l "$p/fd" 2>/dev/null | grep -qE '/dev/snd|/dev/audio|/dev/aud' \
		&& echo "  $p $(cat $p/comm 2>/dev/null)   $(ls -l $p/fd 2>/dev/null | grep -oE '/dev/(snd/[a-zA-Z0-9]*|aud[a-zA-Z0-9_]*)' | sort -u | tr '\n' ' ')"
done

sect "live audio module instances (the module graph in use)"
ls -l /proc/aaudio/instances/ 2>/dev/null

sect "registered implementations per processor"
for d in /proc/aaudio/processors/*/; do
	[ -d "$d" ] || continue
	echo "-- $(basename "$d"): $(ls "$d" 2>/dev/null | tr '\n' ' ')"
done

sect "*** playback module on dsp2 -- does stock use it at all? ***"
found=0
for d in /proc/aaudio/processors/dsp2/playback/*/; do
	[ -d "$d" ] || continue
	found=1
	echo "--- $d"
	cat "$d/prop" 2>/dev/null
	cat "$d/status" 2>/dev/null
done
[ "$found" = 0 ] && echo "NO playback instance -> stock is not using the ALSA PCM path right now"

sect "every live instance: prop + status"
for d in /proc/aaudio/processors/*/*/*/; do
	[ -d "$d" ] || continue
	[ -e "$d/prop" ] || continue
	echo "--- $(echo "$d" | sed 's|/proc/aaudio/processors/||')"
	cat "$d/prop" 2>/dev/null
	cat "$d/status" 2>/dev/null
done

sect "driver's own sndout / amixer status dumps"
cat /proc/aaudio/seetv/sndout 2>/dev/null
echo "--- amixer ---"
cat /proc/aaudio/seetv/amixer 2>/dev/null

sect "full mixer state (compare against our stock-amixer.txt)"
amixer -c 0 contents 2>/dev/null

sect "audio-related processes"
ps 2>/dev/null | grep -iE 'audio|aud|pulse|starfish|media' | grep -v grep

sect "audio-related dmesg"
dmesg 2>/dev/null | grep -iE 'aplayback|aud_kaimc|alsasndout|alsadec|fwload|playback_0' | tail -60
