#!/bin/sh
# audio-up.sh - bring the LG o22 audio path up far enough to play PCM.
#
# Replaces what LG's audiod does on stock. The control VALUES here are not
# guessed: they are taken from a stock webOS dump of a working configuration
# (stock-amixer.txt), which is the only reliable source -- the sequence lives
# in audiod and is not described anywhere in the GPL tree.
#
# Run as a file, not pasted into the serial console: the UART drops characters
# under load ("ttyAMA0: input overrun(s)") and a truncated value silently
# changes meaning (a mangled 'Mute Output 1,0' becomes 'mute=1').
#
# What stock has, and why each matters:
#   LGSE SoundEngine Init        5  LGSE_INIT_LGSE_ATMOS_AISOUND (default 0 =
#                                   UNKNOWN, which leaves the SE pipeline unset
#                                   -> "no set type_info by no set pipeline")
#   LGSE SoundEngine Mode        3  LGSE_MODE_LGSE_ATMOS (default 0 = UNKNOWN)
#   LGSE SE Index Matched Output 0,255,255   spk->LGSE_SPK(0), bt/arc->NONE(255)
#   Sndout MainAudio Output      1,0  COMMON_INPUT_ADEC port 0 -- NOT the
#                                   AMIXER input; stock's main audio is the
#                                   decoder, and the PCM renderer is a separate
#                                   mixer input that gets summed in
#   Sndout Open                  3  COMMON_SPK|COMMON_OPTIC
#   Sndout Spk Output            1,0,0,0
#   Mute Output                  slots 0 (SPK) and 1 (OPTIC) unmuted; outputs
#                                   default to MUTED (alsa_sndout.c:7026)
#
# Note 'Mute Input' is an (index,value) PAIR and 'Gain Input' is an
# (input,port,gain) TRIPLE -- not flat arrays -- and
# 'Master Playback Volume'/'Volume0' are dead stubs (vol_put is inside #if 0 in
# alsa_codec.c:246) -- real volume is Gain Output[0], unity = 0x800000.
#
# usage: audio-up.sh [FW_DIR]
#        SE_INIT=1 SE_MODE=1 audio-up.sh  -- LGSE only, no Dolby DAP
#        SKIP_FW=1 audio-up.sh    -- controls only; firmware brought up
#                                    externally by fwload_audio2 (see below)

set -eu

CARD="${CARD:-0}"
FW_DIR="${1:-/lib/firmware}"
HERE=$(dirname "$0")

SPK=1          # COMMON_SPK
AMIXER_IN=16   # COMMON_INPUT_AMIXER (0x10)
PORT=0         # mixer port 0 -> master_index 4 (port + ALSA_SNDOUT_DEC_NUM)

say() { echo "audio-up: $*"; }

# Address controls BY NAME, never by numid resolved from 'amixer controls':
# that listing aborts partway through. The SE *parameter* controls are
# registered against indices from se_get_parameter_list()'s static pre-list,
# and once _pre_parameter_info_loaded is set every later call returns -1, so
# their .info callback fails:
#     alsase ERR _kcontrol_param_info 1237: invalid value 0x310158
# amixer stops enumerating there, which is alphabetically before 'LGSE *' and
# 'Sndout *' -- so every numid lookup for the controls we actually want came
# back empty. Lookup by name does not enumerate and works fine.
# ctl <name> <value> [expected-readback]
# Some controls have different PUT and GET shapes -- 'LGSE SE Index Matched
# Output' is written as (output,index) but reads back as a per-output index
# vector -- so an explicit expected readback can be given.
ctl() {
	name="$1"; want="$2"; expect="${3:-$2}"

	if ! amixer -c "$CARD" cset name="$name" "$want" >/dev/null 2>&1; then
		say "WARN cset '$name' = $want failed (control absent or info broken)"
		return 0
	fi

	got=$(amixer -c "$CARD" cget name="$name" 2>/dev/null \
	      | sed -n 's/^ *: values=//p' | head -1)
	if [ "$got" = "$expect" ]; then
		say "set '$name' = $want"
	else
		say "WARN '$name': wrote $want, expected readback $expect, got $got"
	fi
}

# --- 1. firmware ---------------------------------------------------------------
# Readiness markers: implementations the playback path needs. They appear as
# proc dirs when a DSP reports its module list (register_impl -> proc_mkdir,
# module_list.c:383). A NON-EMPTY processors dir does not mean usable -- a
# partial run leaves some registered and others not -- so test the markers.
MARKERS='dsp2/mixerbin dsp1/output_speaker dsp2/playback'

missing_markers() {
	for m in $MARKERS; do
		[ -d "/proc/aaudio/processors/$m" ] || echo "$m"
	done
}

nmiss=$(missing_markers | grep -c . || true)
nmark=$(echo $MARKERS | wc -w)

if [ "${SKIP_FW:-0}" = 1 ]; then
	# Firmware is being brought up externally -- the stock way:
	#     NO_RUN=1 sh load-audio-fw.sh      # stage only (stock --donot-run)
	#     sh run-lg-bin.sh fwload_audio2    # LG's own binary does the rest
	# fwload_audio2 drives the adebug chardev's ADBG_IO_RESET, which reaches
	# aud_dsp_reset() -> aud_dsp_halt(), aimc_set_dsp_dead(i,false),
	# aimc_stop/start, fwload_reset per core, and then WAITS for every DSP to
	# report "firmware-init-done" (dsp_control.c:544). Our FWLOAD_IOCTL_RUN
	# only does the per-core fwload_reset and never that handshake.
	# With SKIP_FW=1 this script never loads firmware, so a failed external
	# bring-up stays visible instead of being papered over by our RUN path.
	say "SKIP_FW=1 -- not loading firmware"
	[ "$nmiss" = 0 ] || say "WARN markers still missing:$(missing_markers | tr '\n' ' ')"
elif [ "$nmiss" = 0 ]; then
	say "all DSPs already registered, skipping firmware load"
elif [ "$nmiss" = "$nmark" ]; then
	say "no DSPs registered, loading firmware"
	sh "$HERE/load-audio-fw.sh" "$FW_DIR"
else
	# PARTIAL state. Reloading firmware here resets DSPs that already have
	# live modules/instances (dsp1 carries the SE/DAP/aisound), which wedges
	# them -- the symptom is dsp1/output_speaker never coming back. There is
	# no way to clear that at runtime: bm_destroy_block is only reachable
	# through the audio debug chardev, and sndout state cannot be rewound.
	say "ERROR partial DSP state -- missing:$(missing_markers | tr '\n' ' ')"
	say "  Some DSPs are registered and some are not. Refusing to reload"
	say "  firmware into a live stack, which would make it worse."
	say "  REBOOT, then run this script exactly once before anything"
	say "  touches a PCM device."
	exit 1
fi

# --- 2. wait for implementations (registration is async after reset_run) -------
say "waiting for module implementations"
i=0
while [ $i -lt 100 ] && [ -n "$(missing_markers)" ]; do
	i=$((i + 1))
	usleep 200000 2>/dev/null || sleep 1
done

still=$(missing_markers)
if [ -n "$still" ]; then
	say "ERROR never registered:$(echo "$still" | tr '\n' ' ')"
	say "  dmesg | grep -E 'reset aud|audio ready|firmware load failed'"
	say "  reboot if some DSPs are up but not all -- stale blocks from a"
	say "  partial run cannot be cleared at runtime"
	exit 1
fi
say "implementations ready"

# --- 3. sound engine, before the output path is opened ------------------------
# --- sound engine selection -------------------------------------------------
# SE_INIT decides which MODULES the SE pipeline contains; SE_MODE only selects
# among what Init created (se.c:1625-1700). Defaults copied from stock:
#   Init 5 = LGSE_INIT_LGSE_ATMOS_AISOUND  (LGSE + Dolby DAP + AI Sound)
#   Mode 3 = LGSE_MODE_LGSE_ATMOS          (use DAP)
# but in ATMOS mode se.c does:
#       _create_pipeline (&pipeline_core[SE_CORE_ID_DAP], "dap");
#       _set_bypass (pipeline_out.module, true);     <- the SE bypasses ITSELF
# so every sample is processed by the DAP alone. Confirmed live: the se module
# reports bypass_mode=true.
#
# NOT a tuning problem, despite how it looked for a long time. The DAP works
# untuned -- its lstatus shows real input AND real output
# (L :0xb9600000 in, L :0xcd197b00 out). What was silent was the SE's OSD
# volume, set below.
#
# SE_INIT=1 (LGSE_ONLY) + SE_MODE=1 builds the pipeline WITHOUT the dap module
# and leaves the SE un-bypassed. Changing only the mode at runtime does NOT
# remove the dap -- Init has to differ, so this needs a clean boot.
SE_INIT="${SE_INIT:-5}"
SE_MODE="${SE_MODE:-3}"

ctl 'LGSE SoundEngine Init' "$SE_INIT"
ctl 'LGSE SoundEngine Mode' "$SE_MODE"

# --- 4. output path -----------------------------------------------------------
# MainAudio stays on the AMIXER input, NOT stock's '1,0' (COMMON_INPUT_ADEC):
# stock's main audio is the tuner, but our PCM renderer lands on mixer input4
# (AMIXER port 0 -> master_index 4, = port + ALSA_SNDOUT_DEC_NUM). Pointing the
# output at ADEC0 (index 0) would feed it from an input our PCM never reaches.
ctl 'Sndout MainAudio Output' "$AMIXER_IN,$PORT"

# 'Sndout Open' takes ONE output per call and accumulates; the GET returns the
# bitmask of everything opened so far. Stock reading 3 means it opened SPK then
# OPTIC -- writing 3 directly fails convert_type() with "invalid parameter".
ctl 'Sndout Open' "$SPK"

# Now that the output is added and its SE block exists, set the SE index. PUT is
# (output, se_index) = COMMON_SPK(1), LGSE_SPK(0); the GET returns a per-output
# index vector, so the expected readback differs from what is written.
#
# This MUST come after the first Open: _kcontrol_matched_output_put only calls
# alsa_se_set_type() when "block_info != NULL && output_is_added(output)",
# otherwise it logs "block info is null" and alsa_se->current_type stays NULL --
# which is exactly what makes alsa_se_connect_pipeline() fail with
# "no set type_info by no set pipeline" during Open.
ctl 'LGSE SE Index Matched Output' '1,0' '0,255,255'

# No Close/Open re-trigger: alsa_se_connect_pipeline() recovers on its own.
# Its "no set type_info by no set pipeline" is logged BEFORE the recovery block,
# which then resolves the type from se_index_output (forcing LGSE_SPK when the
# name is COMMON_SPK) and calls alsa_se_set_type() itself. Neither "block info
# is null" nor "type info is NULL" follows, so the error line is noise.

ctl 'Sndout Spk Output' '1,0,0,0'
# GET pads to 9 values.
ctl 'Sndout Connect' "$SPK,$AMIXER_IN,$PORT" "$SPK,$AMIXER_IN,$PORT,0,0,0,0,0,0"

# Outputs default to muted. Unmute SPK (slot 0) and OPTIC (slot 1), as stock.
amixer -c "$CARD" cset name='Mute Output' '1,0' >/dev/null 2>&1 || true
amixer -c "$CARD" cset name='Mute Output' '2,0' >/dev/null 2>&1 || true
say "unmuted SPK and OPTIC"

# --- gains -----------------------------------------------------------------
# alsa_sndout_info[0] is static, so param_output[].gain and param_input[].gain
# start at ZERO and nothing initialises them -- sndout_init() does not. Stock
# sets both explicitly (stock-amixer.txt):
#   Gain Input  : 0,8388608 1,8388608 ... 7,8388608
#   Gain Output : 6245466,8388608,8388608,...   ([0] is the speaker, ~0.74)
# 0x800000 = 8388608 is unity. PUT shapes, from alsa_sndout.c:
#   sndout_gain_output(): value[0]=output, value[1]=gain        -> "1,8388608"
#   sndout_gain_input() : value[0]=input, value[1]=port,
#                         value[2]=gain                        -> "16,0,8388608"
# Both GET back as flat vectors, so no readback comparison is attempted.
UNITY=8388608
amixer -c "$CARD" cset name='Gain Output' "$SPK,$UNITY" >/dev/null 2>&1 \
    && say "set 'Gain Output' $SPK,$UNITY (unity)" || say "WARN 'Gain Output' failed"
amixer -c "$CARD" cset name='Gain Input' "$AMIXER_IN,$PORT,$UNITY" >/dev/null 2>&1 \
    && say "set 'Gain Input' $AMIXER_IN,$PORT,$UNITY (unity)" || say "WARN 'Gain Input' failed"
say "Gain Output now: $(amixer -c "$CARD" cget name='Gain Output' 2>/dev/null | sed -n 's/^ *: values=//p')"
say "Gain Input  now: $(amixer -c "$CARD" cget name='Gain Input' 2>/dev/null | sed -n 's/^ *: values=//p')"

# --- SE OSD volume -- THIS is what made the whole path silent ---------------
# The SE applies its own volume after the DAP, and it starts at ZERO. Nothing
# in the kernel initialises it; on stock, LG's closed audio daemon writes it at
# startup. With it at 0 every stage downstream behaves perfectly -- correct
# byte counts, correct cadence, zero underflows -- and ships pure silence, so
# nothing in the logs or the module properties ever looked wrong.
#
# Found by reading each dsp1 instance's lstatus (NOT prop, which omits it):
#     ours   = OSD Volume Gain : 0x00000000   = OSD Volume Index : 0x00000000
#     stock  = OSD Volume Gain : 0x00007004   = OSD Volume Index : 0x00176d37
#
# "LGSE Var Fn009" index 0 is the speaker SE (alsa_se.c:1089), payload
# LGSE_VAR_FN009_NUM = 2 * 4 bytes, and alsa_se.c:960 names them:
#     noti ("Fn009_Var(OSD Volume): ... Gain=0x%X, UI Vol=%d", vol[0], vol[1]);
# so vol[0] = gain, vol[1] = UI volume, little-endian. These are stock's own
# observed values, not invented ones.
#
# Note the driver's noti() for this put does not reach dmesg at the default log
# level -- the absence of a "Fn009_Var" line does NOT mean the write failed.
# Verify with the readback below, or with the module's lstatus.
SE_VOL_GAIN="${SE_VOL_GAIN:-0x7004}"
SE_VOL_UI="${SE_VOL_UI:-0x176d37}"
le32() { v=$(( $1 )); printf '%d,%d,%d,%d' \
	$(( v & 255 )) $(( (v >> 8) & 255 )) $(( (v >> 16) & 255 )) $(( (v >> 24) & 255 )); }
SE_VOL_BYTES="$(le32 "$SE_VOL_GAIN"),$(le32 "$SE_VOL_UI")"
if amixer -c "$CARD" cset name='LGSE Var Fn009' "$SE_VOL_BYTES" >/dev/null 2>&1; then
	say "set SE OSD volume gain=$SE_VOL_GAIN ui=$SE_VOL_UI ($SE_VOL_BYTES)"
else
	say "WARN 'LGSE Var Fn009' failed -- output will be SILENT"
fi
say "SE OSD volume now: $(amixer -c "$CARD" cget name='LGSE Var Fn009' 2>/dev/null | sed -n 's/^ *: values=//p')"

# --- 5. report ----------------------------------------------------------------
echo
for n in 'Mute Output' 'LGSE SoundEngine Init' 'LGSE SoundEngine Mode' 'Sndout Connect'; do
	v=$(amixer -c "$CARD" cget name="$n" 2>/dev/null | sed -n 's/^ *: values=//p' | head -1)
	printf '  %-30s %s\n' "$n" "${v:-<unreadable>}"
done
echo
say "stock reference: Mute Output 0,0,1,1,...  SE Init 5  SE Mode 3"
say "                Sndout Connect 3,1,0,1,0,16,7,16,6"
say "test: speaker-test -D hw:$CARD,0 -c 2 -t sine -l 1"
