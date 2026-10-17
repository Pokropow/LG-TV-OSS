#!/bin/sh
# load-audio-fw.sh - stage the LG o22 audio DSP firmware, the way stock does.
#
# Mirrors /etc/systemd/system/scripts/firmware_audio.sh from stock webOS,
# minus the parts that need LG's userspace (audpera, fwload_audio2).
#
# Stock stages every image with --donot-run and then calls fwload_audio2,
# which is not in the GPL tree. Something has to start the cores afterwards,
# and in this kernel nothing does on its own: the only in-tree caller of
# _aud_dsp_reset() is the platform driver's *resume* callback
# (core/aud/platform.c:198, guarded by drv_data->is_suspended), so it never
# fires during a normal boot. A staged-but-never-started DSP shows up as:
#
#   auimc     ERR ausrimc_post_imc  720: no such processor number. 0
#   amodlist  ERR aud_modlist_create_inst 1192: no such implementation on -1
#   aplayback ERR aplayback_open     397: Error in playback module create ...
#   lgsic-aplayback: ASoC: can't open component lgsic-aplayback: -5
#
# So the LNE blobs are staged (-n), and each DSP rom image is staged *and*
# run: FWLOAD_IOCTL_RUN -> reset_run() halts the core, copies the rom to DDR,
# pulses reset and releases the halt. Watch for "reset audN done." in dmesg.
#
# The kernel opens these paths itself (kernel_read_file_from_path), so FW_DIR
# must be a real absolute path -- e.g. the stock /lib/firmware on a mounted
# emmc partition, or a copy in the Alpine rootfs.
#
# usage: load-audio-fw.sh [FW_DIR]
#        NO_RUN=1 load-audio-fw.sh   -- stage only, like stock's --donot-run          (default /lib/firmware)
#        AUDFWLOAD=/path/to/audfwload load-audio-fw.sh

set -eu

FW_DIR="${1:-/lib/firmware}"
AUDFWLOAD="${AUDFWLOAD:-audfwload}"

if ! command -v "$AUDFWLOAD" >/dev/null 2>&1 && [ ! -x "$AUDFWLOAD" ]; then
	echo "load-audio-fw: $AUDFWLOAD not found (build alpine/tools/audfwload.c)" >&2
	exit 1
fi

mkdir -p /mnt/mmc27
mountpoint -q /mnt/mmc27 || mount -o ro /dev/mmcblk0p27 /mnt/mmc27
mkdir -p /lib/firmware
ln -sf /mnt/mmc27/lib/firmware/* /lib/firmware/

[ -d "$FW_DIR" ] || { echo "load-audio-fw: no such dir: $FW_DIR" >&2; exit 1; }

# --- chip revision, same selection order as stock -----------------------------
# chip_rev looks like "0x26a2": minor is everything from index 4 ("a2"),
# major is the two hex digits before it ("26"). Stock tries the exact minor,
# then <first letter>0, then a0, and takes the first one with a dsp0 image.
if [ -r /proc/lg/base/chip_rev ]; then
	chip_rev=$(cat /proc/lg/base/chip_rev)
else
	echo "load-audio-fw: /proc/lg/base/chip_rev unreadable; assuming a0" >&2
	chip_rev="0x26a0"
fi

rev_minor=$(printf '%s' "$chip_rev" | cut -c5-)
rev_major_hex=$(printf '%s' "$chip_rev" | cut -c3-4)
rev_major=$((0x$rev_major_hex))

selected_rev=""
for rev in "$rev_minor" "$(printf '%s' "$rev_minor" | cut -c1)0" a0; do
	if [ -f "$FW_DIR/audio_${rev}_dsp0.bin" ]; then
		selected_rev="$rev"
		break
	fi
done

if [ -z "$selected_rev" ]; then
	echo "load-audio-fw: no audio_*_dsp0.bin in $FW_DIR" >&2
	exit 1
fi

echo "load-audio-fw: chip_rev=$chip_rev major=0x$rev_major_hex -> rev '$selected_rev'"

# --- LNE (sound engine) model/weight blobs ------------------------------------
# Below chip major 0x28 these go onto /dev/fwload_aud1 under their own image
# names; from 0x28 they go to a separate audio_lnx device with more files.
if [ "$rev_major" -ge $((0x28)) ]; then
	lne_dest=/dev/fwload_audio_lnx
	lne_files="model1 model2 model4 weight1 weight2 weight4"
else
	lne_dest=/dev/fwload_aud1
	lne_files="model weight1 weight2 weight4"
fi

lne_args=""
for type in $lne_files; do
	f="$FW_DIR/lne_${selected_rev}_${type}.bin"
	[ -f "$f" ] && lne_args="$lne_args ${type}:${f}"
done

if [ "${SKIP_LNE:-0}" = 1 ]; then
	# dsp1 is the only core that gets LNE images staged alongside its rom,
	# both out of audio_buffer0. If dsp1 fails to register while dsp0/2/3
	# come up, skip these to test whether the LNE staging is the cause.
	# They only provide sound-engine extras (AI Sound); basic PCM playback
	# should not need them.
	echo "load-audio-fw: SKIP_LNE=1 -- not staging LNE blobs"
	lne_args=""
fi

if [ -n "$lne_args" ] && [ -c "$lne_dest" ]; then
	echo "load-audio-fw: LNE -> $lne_dest"
	# shellcheck disable=SC2086
	"$AUDFWLOAD" -n "$lne_dest" $lne_args
else
	echo "load-audio-fw: no LNE blobs found (sound engine features will be absent)"
fi

# --- the four DSP rom images --------------------------------------------------
# Stock's order is dsp2, dsp3, dsp1, dsp0 -- dsp0 last. Kept identical, since
# dsp0 is the one the ALSA playback path reaches first.
for n in 2 3 1 0; do
	dev="/dev/fwload_aud${n}"
	img="$FW_DIR/audio_${selected_rev}_dsp${n}.bin"

	if [ ! -c "$dev" ]; then
		echo "load-audio-fw: $dev absent, skipping"
		continue
	fi
	if [ ! -f "$img" ]; then
		echo "load-audio-fw: $img missing, skipping $dev" >&2
		continue
	fi

	# Stage, and start the core unless NO_RUN=1.
	#
	# NO_RUN=1 reproduces stock exactly: firmware_audio.sh stages every image
	# with --donot-run and the cores are started afterwards by fwload_audio2
	# (a binary, not in the GPL tree). Use it when running LG's own
	# fwload_audio2 via run-lg-bin.sh instead of our FWLOAD_IOCTL_RUN.
	if [ "${NO_RUN:-0}" = 1 ]; then
		"$AUDFWLOAD" -n "$dev" "rom:${img}"
	else
		"$AUDFWLOAD" "$dev" "rom:${img}"
	fi
done

echo
echo "load-audio-fw: done. check with:"
echo "  dmesg | grep -E 'reset aud[0-9] done|firmware load failed'"
echo "  for n in 0 1 2 3; do cat /proc/mcu/aud\$n/status; done"
echo "  speaker-test -D hw:0,0 -c 2 -t sine -l 1"
