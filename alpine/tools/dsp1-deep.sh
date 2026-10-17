#!/bin/sh
# dsp1-deep.sh - the two things never looked at: status/lstatus, and TRACE.
#
# STATUS (2026-10-17): AUDIO WORKS. The cause was the SE's OSD volume sitting
# at zero -- `audio-up.sh` now writes "LGSE Var Fn009". Everything below this
# line was written while it was still broken, so its "state of play" is
# history, not current fact. The tool itself is still good for debugging.
#
# Where this sits. dsp1 is handed correct audio -- our out2 hand-off carries a
# clean sine in stock's exact 8-word frame layout -- and writes zeros to the
# DAC. bc-probe.sh (now in ../tools_unused/) proved output_speaker really does
# own the chunk named bc-speaker -- a 0x01 stamp over all 8 KiB was replaced by
# zeros in under 0.5 s -- and that the DAC and analogue path work, since the
# stamp was audible as a click.
# Every dsp1 module prop is byte-identical to stock, the graph is topologically
# identical, the chain runs at stock's cadence with zero underflows.
#
# So the difference is module INTERNAL state, and two sources of it have never
# been read:
#
#   1. status / lstatus. Every instance has prop, cmd, status and lstatus;
#      audio-snapshot.sh only ever collected prop. Whatever a module reports
#      about its own running state lives in the other two.
#
#   2. log-mask 0xffffffff (TRACE). Every run so far used 31, which stops at
#      debug. A module complaining about uninitialised coefficients would do it
#      at trace level.
#
# Trace is raised on dsp1/dap and dsp1/se ONLY. Raising it on all 27 live
# instances is what wedged the box before -- and note that was with
# ignore_loglevel on the cmdline clocking every printk out of ttyAMA0 at 115200;
# boot_kernel.sh now uses loglevel=4, but two modules is still the right dose.
#
# Run this on BOTH boxes. The status/lstatus diff is the valuable half, and it
# needs no tone on stock -- just something playing.
#
# usage:  sh dsp1-deep.sh            (plays its own tone)
#         TONE=0 sh dsp1-deep.sh     (on stock)

set -u
P=/proc/aaudio/processors
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

say "===== every dsp1 instance: status and lstatus ====="
for d in "$P"/dsp1/*/*/; do
	[ -d "$d" ] || continue
	say "--- ${d#$P/}"
	for f in status lstatus; do
		[ -r "$d$f" ] || continue
		echo "    [$f]"
		sed 's/^/      /' "$d$f" 2>/dev/null | head -40
	done
done

say "===== dsp2/mixerbin, same ====="
for d in "$P"/dsp2/mixerbin/*/; do
	[ -d "$d" ] || continue
	for f in status lstatus; do
		[ -r "$d$f" ] || continue
		echo "    [$f]"
		sed 's/^/      /' "$d$f" 2>/dev/null | head -40
	done
done

# TRACE on dap and se only.
say "===== raising log-mask to 0xffffffff on dsp1/dap + dsp1/se ====="
n=0
for m in dap se; do
	for d in "$P"/dsp1/$m/*/; do
		[ -e "$d/prop" ] || continue
		echo "log-mask 4294967295" > "$d/prop" 2>/dev/null && n=$((n + 1))
		say "raised ${d#$P/}"
	done
done
say "raised $n instance(s)"

usleep 200000 2>/dev/null || sleep 1
dmesg -c >/dev/null 2>&1
sleep 2

say "===== everything dap and se said at trace level ====="
dmesg | grep -aE 'dap_|se_03|lgse|LGSE|coef|param|init|bypass' \
      | sed -e 's/.*aud_kaimc.*aud[0-9]  *[0-9]*: *[0-9.]*\] */DSP /' \
      | sed 's/^/  /' | head -80

say "===== distinct dap/se log sites (what it ever says) ====="
dmesg | grep -aoE '(dap|se)_[a-z_]*\.[ ]*[0-9]+' | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'

# Put it back: trace on these two is expensive to leave on.
for m in dap se; do
	for d in "$P"/dsp1/$m/*/; do
		[ -e "$d/prop" ] || continue
		echo "log-mask 7" > "$d/prop" 2>/dev/null
	done
done
say "log-mask restored to 7"

[ -n "$st" ] && { kill $st 2>/dev/null; wait $st 2>/dev/null; }
say "done"
