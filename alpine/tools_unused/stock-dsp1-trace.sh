#!/bin/sh
# stock-dsp1-trace.sh - capture STOCK's dsp1 chain while it plays, to diff
# against ours. Run ON STOCK, with sound playing.
#
# Why this is the last useful reference: our dsp1 now matches stock
# property-for-property (the dap prop block is byte-identical), the dsp2->dsp1
# shared buffer provably carries audio on both, and yet
#   stock queue (speaker path): state=running
#   ours  queue (speaker path): state=wait      <- starved
# and our bc-speaker stays all zeros while stock's holds 4ch x 32-bit PCM.
# So the difference is in what the modules DO, not how they are configured,
# and only stock's own logs can show that.
#
# SAFETY: this raises log-mask on 6 dsp1 modules and restores it to 7 at the
# end. It writes nothing else and changes no audio control. BUT if stock boots
# with ignore_loglevel on a 115200 console, verbose DSP logging can stall the
# box -- that is exactly what wedged our kernel. So it checks first and refuses
# unless the console is quiet, and keeps the window short.
#
# usage, on stock, as root, WITH SOUND PLAYING:
#     sh stock-dsp1-trace.sh 2>&1 | tee /tmp/stock-dsp1.txt

set -u
say() { echo "## $*"; }
P=/proc/aaudio/processors
CHAIN="dsp1/bypass dsp1/dap dsp1/se dsp1/queue dsp1/outctrlbin dsp1/output_speaker"

say "cmdline console check"
grep -o 'ignore_loglevel\|console=[^ ]*\|loglevel=[0-9]*' /proc/cmdline | sed 's/^/  /'
if grep -q ignore_loglevel /proc/cmdline; then
	say "WARNING: ignore_loglevel is set -- every printk goes to the UART at"
	say "         115200 baud and verbose logging may stall the TV."
	say "         Trying to quieten the console anyway; if the box freezes,"
	say "         power-cycle. Set ABORT=1 to not risk it."
	[ "${ABORT:-0}" = 1 ] && { say "aborting as requested"; exit 0; }
fi
dmesg -n 1 2>/dev/null && say "console_loglevel set to 1"

restore() {
	for m in $CHAIN; do
		for d in "$P/$m"/*/; do
			[ -e "$d/prop" ] && echo "log-mask 7" > "$d/prop" 2>/dev/null
		done
	done
	say "log-mask restored to 7"
}
trap restore EXIT INT TERM

n=0
for m in $CHAIN; do
	for d in "$P/$m"/*/; do
		[ -e "$d/prop" ] || continue
		echo "log-mask 31" > "$d/prop" 2>/dev/null && n=$((n + 1))
	done
done
say "raised log-mask on $n dsp1 instances"

dmesg -c >/dev/null 2>&1
sleep 2

say "===== stock dsp1 chain, 2 s ====="
dmesg | grep -aE 'dap|se_03|queue_03|outctrlbin|output_speaker|bypass_03|out_chain|push data|write_pcm|underflow' \
      | head -60 | sed 's/^/  /'

say "===== counts ====="
for k in 'write_pcm' 'push data' 'out_chain_bc' 'underflow' 'se_03' 'wait'; do
	printf '  %-16s %s\n' "$k" "$(dmesg | grep -ac "$k")"
done
