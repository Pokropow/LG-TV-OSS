#!/bin/sh
# shared-peek2.sh - find the REAL audio in each buffer, ignoring the fill pattern.
#
# STATUS (2026-10-17): AUDIO WORKS. The cause was the SE's OSD volume sitting
# at zero -- `audio-up.sh` now writes "LGSE Var Fn009". Everything below this
# line was written while it was still broken, so its "state of play" is
# history, not current fact. The tool itself is still good for debugging.
#
# Why v1 was not enough. It picked each chunk's "densest" 4 KiB block and
# dumped that. On BOTH our kernel and stock, that selected a block of the
# repeating 16-byte fill pattern
#
#     f4e201ff a5ee1bcc 7823f96d 34ba123b
#
# because the pattern is 100% non-zero while real PCM is only ~50% non-zero
# (half the 32-bit words are a silent channel, and 24-bit samples carry a 00
# high byte). Stock plays audio and shows the same pattern, so its presence
# proves nothing -- it is untouched memory, not silence. Non-zero COUNT cannot
# separate the two.
#
# What does separate them: how many DISTINCT 32-bit words a block holds. The
# fill pattern has exactly 4. Real PCM has hundreds. So every block is scored
# by unique-word count and the map marks:
#
#     .  empty          P  fill pattern (<= 8 distinct words)
#     :  sparse audio   *  dense audio
#
# and the block dumped is the one with the MOST DISTINCT words, which is the
# audio, never the pattern.
#
# What to look for. Stock's bc-hp shows the DAC's real 4-channel layout:
#     006170b3 00614cf7 00000000 00000000     24-bit L,R in ch0/ch1, ch2/ch3 zero
# and a 440 Hz sine appears as a smooth ramp, as alsa_playback does:
#     62b30000 641d0000 65330000 65f20000
#
# bc-speaker gets a finer 512-byte breakdown as well: it is only 8 KiB, the
# module claims bc-filled=6656, and out_chain_bc's write pointer was seen
# ranging over 0x0600..0x1e00 -- so where inside it the audio lands matters.
#
# ALIGNMENT. Every read is done in 512-byte units. bc-speaker starts at
# 0x8304c400 -- 1 KiB aligned but NOT 4 KiB aligned -- so a "dd bs=4096
# skip=addr/4096" truncates to 0x8304c000 and reads bc-sai2 plus only the
# first 3 KiB of bc-speaker. That is what made earlier runs appear to show the
# fill pattern "inside" bc-speaker on both boxes; it was the neighbouring
# chunk. Never assume 4 KiB alignment for an HMA chunk.
#
# Chunks are resolved BY NAME. The pool layout differs between the two boxes:
# stock has four mixerbin chunks to our three, and 0x86b15000 is a mixerbin
# buffer on stock but alsa_playback on ours. Any hardcoded address reads the
# wrong memory on the other machine.
#
# usage:  sh shared-peek2.sh            (plays its own tone)
#         TONE=0 sh shared-peek2.sh     (on stock: start playback yourself)

set -u
POOL=/proc/hma/audio_buffer0/status
[ -r "$POOL" ] || POOL=/proc/hma/audio_buffer/status
[ -r "$POOL" ] || { echo "## no HMA pool status"; exit 1; }

T=/tmp/.sp2.$$
say() { echo "## $*"; }
cleanup() { rm -f "$T"; }
trap cleanup EXIT

# Read one window into $T, then score it twice from the same bytes.
# grab <addr> <bytes>  -- always in 512-byte units, so any 512-aligned
# chunk start is read exactly, with no truncation to a coarser boundary.
grab() { dd if=/dev/mem bs=512 skip=$(( $1 / 512 )) count=$(( $2 / 512 )) 2>/dev/null \
		| od -A n -t x4 -v | tr -s ' ' '\n' | grep -v '^$' > "$T"; }
dump() { dd if=/dev/mem bs=512 skip=$(( $1 / 512 )) count=$(( $2 / 512 )) 2>/dev/null \
		| od -A x -t x4 -v | head -12 | sed 's/^/     /'; }
nz()     { grep -c '[1-9a-f]' "$T"; }
uniq_n() { sort -u "$T" | wc -l; }

BEST=0; BEST_U=-1
map() {
	a="$1"; sz="$2"; nblk=$(( sz / 4096 )); [ "$nblk" -gt 0 ] || nblk=1
	BEST=$a; BEST_U=-1
	i=0; line="     "
	while [ "$i" -lt "$nblk" ]; do
		off=$(( a + i * 4096 ))
		grab "$off" 4096
		n=$(nz); u=$(uniq_n)
		# Most distinct words wins -- that is the audio, not the pattern.
		[ "$u" -gt "$BEST_U" ] && { BEST_U=$u; BEST=$off; }
		if   [ "$n" -eq 0 ];   then line="$line."
		elif [ "$u" -le 8 ];   then line="$line""P"
		elif [ "$n" -lt 512 ]; then line="$line:"
		else                        line="$line*"
		fi
		i=$(( i + 1 ))
	done
	echo "$line"
	echo "     most-distinct 4K block: $BEST_U distinct words, at $(printf '0x%x' $BEST)"
}

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

# mixerbin_* and alsa_playback chunks exist only while the DSP modules and
# the ALSA stream are live. Without them this scans an idle box and every
# buffer reads as zeros for an uninteresting reason.
if ! grep -q 'mixerbin' "$POOL" 2>/dev/null; then
	say "!!! no mixerbin chunk in $POOL -- the audio stack is NOT up."
	say "!!! bring it up first, or this measures an idle box:"
	say "!!!   NO_RUN=1 AUDFWLOAD=/usr/local/bin/audfwload sh load-audio-fw.sh"
	say "!!!   sh run-lg-bin.sh fwload_audio2"
	say "!!!   SKIP_FW=1 sh audio-up.sh"
fi

say "legend:  . empty   P fill-pattern   : sparse audio   * dense audio"

awk '{print $1, $2, $NF}' "$POOL" 2>/dev/null | while read -r a s nm; do
	case "$nm" in
		alsa_playback|mixerbin_*|bc-speaker|bc-hp) ;;
		*) continue ;;
	esac
	say "===== $nm at $a ($(( s / 1024 )) KiB) ====="
	map "$a" "$s"
	say "----- most-distinct block, as 32-bit words -----"
	dump "$BEST" 4096
done

# bc-speaker in 512-byte steps: the DAC ring is only 8 KiB and the write
# pointer moves inside it, so block-level granularity hides where data lands.
awk '$NF == "bc-speaker" { print $1, $2 }' "$POOL" 2>/dev/null \
| while read -r a s; do
	say "===== bc-speaker, 512-byte breakdown ====="
	printf '     %-8s %10s %10s\n' OFFSET NONZERO DISTINCT
	i=0
	while [ "$i" -lt "$(( s / 512 ))" ]; do
		grab $(( a + i * 512 )) 512
		printf '     %-8s %10s %10s\n' "$(printf '0x%04x' $(( i * 512 )))" "$(nz)" "$(uniq_n)"
		i=$(( i + 1 ))
	done
	say "----- bc-speaker at offset 0x400, as 32-bit words -----"
	say "(stock reads 64/128 non-zero in EVERY window: L,R,0,0 per frame)"
	dump $(( a + 1024 )) 1024
done

[ -n "$st" ] && { kill $st 2>/dev/null; wait $st 2>/dev/null; }
say "done"
