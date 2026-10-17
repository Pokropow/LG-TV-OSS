#!/bin/sh
# ring-trace.sh - correlate the kernel's two ring pointers during one stream.
#
# Why: EPIPE from snd_pcm_writei is XRUN (underrun), not "buffer full". If the
# kernel never learned rdOffset, hw_ptr would stay 0 and writes would BLOCK.
# Getting EPIPE instead means the kernel does track rdOffset and sees the DSP
# consume past what userspace wrote -- consistent with wroffset-poke.sh, where
# rdOffset advanced 370 times in 6 s no matter what we set wrOffset to.
#
# So the question is no longer "does rdOffset arrive" but "how does it move
# relative to wrOffset". Two log lines answer it, both in alsa_playback.c:
#   _aplayback_updated  trace("rdOffset is 0x%08x")   <- needs level 'trace'
#   aplayback_ack       "wrOffset ... sw_ptr ... rdOffset ..."
# If rd runs ahead of wr, the DSP is free-running and ignoring the write
# pointer. If rd tracks wr and stops with it, the ring protocol is fine and the
# fault is downstream.
#
# usage:  sh ring-trace.sh [> /tmp/ring-trace.txt 2>&1]

set -u
say() { echo "## $*"; }

say "log levels: aplayback -> trace"
echo 'aplayback:trace' > /proc/logm/status 2>/dev/null || say "WARN logm write failed"

say "clearing dmesg"
dmesg -c >/dev/null 2>&1 || say "note: dmesg -c unavailable, output may include old lines"

say "one short tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 1 >/tmp/speaker-test.log 2>&1
say "speaker-test said:"; sed 's/^/    /' /tmp/speaker-test.log | tail -5

say "===== pointer trace, in order ====="
dmesg | grep -aE 'rdOffset|wrOffset|got callback|wrong hardware pointer|playback_041|aplayback_(trigger|prepare|ack|pointer)' \
      | sed 's/^/  /'

say "===== how many of each ====="
for k in 'got callback' 'rdOffset is' 'wrOffset 0x' 'wrong hardware pointer'; do
	printf '  %-24s %s\n' "$k" "$(dmesg | grep -ac "$k")"
done

say "back to noti"
echo 'aplayback:noti' > /proc/logm/status 2>/dev/null
