#!/bin/sh
# bc-probe.sh - does output_speaker actually write into the chunk named
#               bc-speaker, or somewhere else?
#
# Everything else is now accounted for. dsp1 receives correct audio: our out2
# hand-off buffer carries a clean sine in stock's exact 8-word frame layout
# (stock fills slots 6+7 for a mono source, we fill slot 7 because
# speaker-test drives one channel at a time). The dsp1 graph is topologically
# identical to stock's, every module prop matches, the chain runs at stock's
# cadence with zero underflows, and output_speaker reports bc-filled=6656.
# Yet bc-speaker reads as 8 KiB of zeros where stock has 64/128 non-zero words
# in every 512-byte window.
#
# The untested assumption: that output_speaker writes THERE. Untouched memory
# in this pool is not zero, it is the repeating fill pattern
# f4e201ff a5ee1bcc 7823f96d 34ba123b -- so an all-zero bc-speaker is equally
# consistent with:
#
#   (a) the module writes here, and the data is silence         <- assumed
#   (b) the module writes elsewhere, and this chunk was merely
#       allocated and zeroed, never touched                     <- untested
#
# This distinguishes them. Stamp the buffer with a known value, let the stream
# run, and read it back:
#
#   stamp gone, zeros returned -> (a) the module owns this buffer and writes
#                                 silence into it. The fault is dsp1's data.
#   stamp still there          -> (b) the module writes somewhere else, every
#                                 bc-speaker measurement so far was of the
#                                 wrong memory, and the real buffer must be
#                                 found before anything else makes sense.
#
# The stamp is the byte 0x01 repeated, i.e. words of 0x01010101 ~= 0.8% of
# full scale as a 32-bit sample -- comparable to stock's observed level
# (0x020cb6e6), so if the DAC is live this is a quiet click, not a blast.
# Deliberately NOT 0xAA or 0x55: as signed 32-bit those are near full scale
# and would slam the speakers.
#
# A bonus reading: if stamping produces an AUDIBLE click or buzz, the DAC and
# the whole analogue path are proven working and the fault is definitively
# upstream data. Silence here is not conclusive on its own, but a click is.
#
# Writes to /dev/mem need CONFIG_STRICT_DEVMEM off, which it is on this build.
# Step 2 verifies the stamp actually landed before anything is concluded.
#
# usage:  sh bc-probe.sh [> /tmp/bc-probe.txt 2>&1]

set -u
POOL=/proc/hma/audio_buffer0/status
[ -r "$POOL" ] || POOL=/proc/hma/audio_buffer/status
say() { echo "## $*"; }

set -- $(awk '$NF == "bc-speaker" { print $1, $2; exit }' "$POOL" 2>/dev/null)
[ $# -eq 2 ] || { say "bc-speaker not in $POOL -- is the audio stack up?"; exit 1; }
A="$1"; S="$2"
SEEK=$(( A / 512 )); CNT=$(( S / 512 ))
say "bc-speaker at $A, $(( S / 1024 )) KiB  (512-byte units: seek=$SEEK count=$CNT)"

# Non-zero 32-bit words over the whole chunk, read in 512-byte units because
# this chunk is 1 KiB aligned, NOT 4 KiB aligned.
scan() {
	dd if=/dev/mem bs=512 skip="$SEEK" count="$CNT" 2>/dev/null \
		| od -A n -t x4 -v | tr -s ' ' '\n' | grep -v '^$' > /tmp/.bcp.$$
	printf 'non-zero %s / %s words, %s distinct' \
		"$(grep -c '[1-9a-f]' /tmp/.bcp.$$)" \
		"$(wc -l < /tmp/.bcp.$$)" \
		"$(sort -u /tmp/.bcp.$$ | wc -l)"
	rm -f /tmp/.bcp.$$
}
head4() { dd if=/dev/mem bs=512 skip="$SEEK" count=1 2>/dev/null \
		| od -A x -t x4 -v | head -4 | sed 's/^/     /'; }

say "starting tone"
speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 \
	>/tmp/speaker-test.log 2>&1 &
st=$!
sleep 3

say "===== 1. before the stamp ====="
say "$(scan)"; head4

say "===== 2. stamping 0x01 over all $(( S / 1024 )) KiB ====="
tr '\000' '\001' < /dev/zero 2>/dev/null \
	| dd of=/dev/mem bs=512 seek="$SEEK" count="$CNT" conv=notrunc 2>/dev/null
say "immediately after write: $(scan)"
head4
say "(if this is not ~all 01010101, the /dev/mem write itself failed and"
say " nothing below means anything)"

say "===== 3. after 0.5 s of playback ====="
usleep 500000 2>/dev/null || sleep 1
say "$(scan)"; head4

say "===== 4. after a further 2 s ====="
sleep 2
say "$(scan)"; head4

kill $st 2>/dev/null; wait $st 2>/dev/null

say "===== out_chain_bc, for correlation ====="
dmesg | grep -a 'out_chain_bc' | tail -3 | sed 's/^/     /'
say ""
say "READ IT LIKE THIS:"
say "  stamp replaced by ZEROS  -> output_speaker owns this buffer and is"
say "                              writing silence. The fault is dsp1 data."
say "  stamp SURVIVES           -> it writes elsewhere; find the real buffer."
say "  you HEARD a click/buzz   -> DAC and analogue path are proven good."
