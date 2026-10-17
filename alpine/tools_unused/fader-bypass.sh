#!/bin/sh
# fader-bypass.sh - bypass the mixer-input fader while a PCM stream is open.
#
# Why this exists: playback on the LG o22 audio path dies with
#
#   fader_04190001 ... _fader_process_data_fadeout. 789: send zero data...
#   Write error: -32 (EPIPE)
#
# The fader sits in the mixer's INPUT pipeline (mixer.c:694,
# apipeline_appendf(pipeline_input, "fader")) and mixer_set_bypass_fader()
# drives it with the property "bypass" (mixer.c:737). Every module instance
# exposes a writable prop file (module_list.c:1119), so the fader can be
# bypassed from the shell without rebuilding anything.
#
# The catch: /proc/aaudio/processors/dsp2/fader/ holds only 'status' when idle.
# That is the IMPLEMENTATION directory. Instance directories are named by the
# instance uid in hex (module_list.c:1112, proc_mkdir("%08x")) and carry
# cmd/prop/status/lstatus -- but they exist only while the instance does, i.e.
# only while the PCM is open. So poll for them and write as soon as they appear.
#
# NOTE the write format: proc_inst_prop() (module_list.c:854) reads argv[0] and
# argv[1] as separate tokens and builds "%s=%s" itself, so write
#     bypass 1        <- space, NOT bypass=1
#
# usage, in one shell:
#     sh fader-bypass.sh &
#     speaker-test -D hw:0,0 -c 2 -t sine -l 0
#
# or, to keep bypassing every new instance (for rc-local):
#     WATCH=1 sh fader-bypass.sh &
#
# or point it at a different module/processor:
#     MOD=fader PROC=dsp2 sh fader-bypass.sh

set -u

PROC="${PROC:-dsp2}"
MOD="${MOD:-fader}"
PROP="${PROP:-bypass}"
VAL="${VAL:-1}"
TRIES="${TRIES:-400}"          # x 50ms = ~20s

DIR="/proc/aaudio/processors/$PROC/$MOD"

say() { echo "fader-bypass: $*"; }

[ -d "$DIR" ] || { say "no such module dir: $DIR"; exit 1; }

say "waiting for a '$MOD' instance on $PROC (open a PCM now)"

# The instance is created and destroyed with each PCM open, and a fresh one
# starts un-bypassed, so WATCH=1 keeps applying it. That is the mode to use
# from rc-local; the one-shot mode is for interactive testing.
seen=""
i=0
done_any=0

while :; do
	for d in "$DIR"/*/; do
		[ -d "$d" ] || continue
		[ -e "$d/prop" ] || continue

		id=$(basename "$d")
		case " $seen " in *" $id "*) continue ;; esac

		# proc_inst_prop wants two tokens: <name> <value>
		if echo "$PROP $VAL" > "$d/prop" 2>/dev/null; then
			say "set '$PROP $VAL' on $id"
			seen="$seen $id"
			done_any=1
		else
			say "WARN write failed on $id"
		fi
	done

	if [ "${WATCH:-0}" = 1 ]; then
		# Forget instances that have gone away, so their uid can be
		# bypassed again if it is reused on the next open.
		fresh=""
		for id in $seen; do
			[ -d "$DIR/$id" ] && fresh="$fresh $id"
		done
		seen="$fresh"
		usleep 50000 2>/dev/null || sleep 1
		continue
	fi

	[ "$done_any" = 1 ] && break
	i=$((i + 1))
	[ "$i" -ge "$TRIES" ] && break
	usleep 50000 2>/dev/null || sleep 1
done

if [ "$done_any" != 1 ]; then
	say "no '$MOD' instance appeared within the timeout"
	say "  live instances: $(ls /proc/aaudio/instances/ 2>/dev/null | tr '\n' ' ')"
	say "  impl status:    cat $DIR/status"
	exit 1
fi

say "done -- if the tone comes through, the fader was the blocker"
