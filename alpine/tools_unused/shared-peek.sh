#!/bin/sh
# shared-peek.sh - what exactly crosses from dsp2 into dsp1, as a WAVEFORM?
#
# State of play: the whole dsp1 chain (gluepr -> bypass -> dap -> se -> queue
# -> outctrlbin -> output_speaker) runs at stock's cadence with stock's byte
# counts and zero underflows -- dap_chain fires once per dap_write_pcm, the
# speaker glue delivers +8192 per cycle, out_chain_bc writes 2048-byte blocks
# into bc-speaker, and output_speaker reports bc-filled=6656 (stock: 5632).
# bc-speaker still reads as 8 KiB of zeros. So dsp1 is moving silence.
#
# The question this answers: is the silence already there when it arrives?
#
# Every previous attempt measured "non-zero density" -- the count of non-00
# bytes over a whole chunk. That metric has now produced two wrong conclusions
# (a 2 KiB sample of a 256 KiB ring, and a channel-slot that just tracked the
# write pointer), and it cannot tell a clean sine from sparse garbage. So:
#
#   1. walk each chunk in 4 KiB blocks and count non-zero 32-bit WORDS,
#      which localises where in the ring the data actually is
#   2. hexdump the densest block as 32-bit words, where a 440 Hz sine is
#      unmistakable -- smooth monotonic ramps, as alsa_playback shows:
#          e9f4 0000  efc0 0000  f59a 0000  fb7c 0000  0163 0000 ...
#      (L ascending, R zero: speaker-test drives one channel at a time)
#   3. repeat 1 s later, so a block that moved proves the data is live
#      rather than stale from an earlier run
#
# Chunks are found by NAME, never by address: the pool layout differs between
# our kernel and stock, and hardcoding 0x86ad5000 would silently read the
# wrong memory on the other box.
#
# usage:  sh shared-peek.sh            (plays its own tone)
#         TONE=0 sh shared-peek.sh     (on stock: start playback yourself first)

set -u
POOL=/proc/hma/audio_buffer0/status
[ -r "$POOL" ] || POOL=/proc/hma/audio_buffer/status
[ -r "$POOL" ] || { echo "## no HMA pool status"; exit 1; }

say() { echo "## $*"; }

st=""
if [ "${TONE:-1}" = 1 ]; then
	say "starting tone"
	speaker-test -D hw:0,0 -c 2 -t sine -l 0 -b 680000 -p 170000 \
		>/tmp/speaker-test.log 2>&1 &
	st=$!
	sleep 3
else
	say "TONE=0 -- assuming something is already playing"
fi

# Non-zero 32-bit words in one 4 KiB block (1024 words). Counting WORDS, not
# bytes: a 16-bit sample whose high byte is 00 still counts as signal here,
# which is exactly what the byte-density metric got wrong.
blk_nz() {
	dd if=/dev/mem bs=4096 skip="$1" count=1 2>/dev/null \
		| od -A n -t x4 -v | tr -s ' ' '\n' | grep -c '[1-9a-f]'
}

# Walk a chunk in 4 KiB blocks; print the map and remember the densest block.
BEST=0; BEST_NZ=0
map() {
	a="$1"; sz="$2"; nblk=$(( sz / 4096 ))
	[ "$nblk" -gt 0 ] || nblk=1
	base=$(( a / 4096 ))
	BEST=$base; BEST_NZ=-1
	i=0; line="     "
	while [ "$i" -lt "$nblk" ]; do
		nz=$(blk_nz $(( base + i )))
		[ "$nz" -gt "$BEST_NZ" ] && { BEST_NZ=$nz; BEST=$(( base + i )); }
		# one glyph per 4 KiB: . empty, : sparse, * dense
		if   [ "$nz" -eq 0 ];    then line="$line."
		elif [ "$nz" -lt 512 ];  then line="$line:"
		else                          line="$line*"
		fi
		i=$(( i + 1 ))
	done
	echo "$line"
	echo "     densest 4K block: $BEST_NZ/1024 non-zero words"
}

for want in alsa_playback mixerbin_04280001 bc-speaker bc-hp; do
	awk -v n="$want" '$NF == n { print $1, $2 }' "$POOL" 2>/dev/null \
	| while read -r a s; do
		say "===== $want at $a ($(( s / 1024 )) KiB) ====="
		map "$a" "$s"
		say "----- densest block, as 32-bit words -----"
		dd if=/dev/mem bs=4096 skip="$BEST" count=1 2>/dev/null \
			| od -A x -t x4 -v | head -16 | sed 's/^/     /'
	done
done

say "===== second pass, 1 s later (a moved block = live data) ====="
sleep 1
for want in mixerbin_04280001 bc-speaker; do
	awk -v n="$want" '$NF == n { print $1, $2 }' "$POOL" 2>/dev/null \
	| while read -r a s; do
		say "----- $want at $a -----"
		map "$a" "$s"
	done
done

[ -n "$st" ] && { kill $st 2>/dev/null; wait $st 2>/dev/null; }
say "done"
