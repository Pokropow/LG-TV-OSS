#!/bin/sh
# boot_kernel.sh - kexec into our kernel from the running stock webOS.
#
# Runs ON THE TV. Image, boot-initramfs.cpio.gz, tv.dtb, kexec and
# fix_stuck_cpus.ko must be in $MY_STUFF (default /home/root/my_stuff).
#
# The kernel command line is assembled from two halves:
#
#   tv-env.sh   values belonging to ONE physical television -- MAC address,
#               serial number, sbkey, AVS silicon calibration, model/region
#               options. Gitignored. See tv-env.example.sh for how to read
#               them off your own set's /proc/cmdline.
#
#   OURS        below: everything this project adds or overrides. Generic,
#               safe to publish, the same on any o22 set.
#
# TWO WAYS TO RUN IT, and the script detects which:
#
#   1. Over ssh with nothing stored on the TV -- preferred, because the serial
#      number and MAC never touch the television's filesystem:
#
#        cat tv-env.sh boot_kernel.sh | ssh root@<tv> "bash -s"
#
#      The env file is prepended, so the variables are already set by the time
#      this script runs and no file is looked for. Note that piping the script
#      alone would leave them unset, which is why they are validated below.
#
#   2. As a file on the TV, with tv-env.sh copied next to it:
#
#        sh /home/root/my_stuff/boot_kernel.sh
#
# Stock webOS is untouched by all of this -- power-cycle the TV and it comes
# back normally.

set -u

# Not derived from $0: when the script is piped in over ssh ("bash -s") there
# is no script file, $0 is "bash", and dirname gives ".". Hardcode the payload
# directory instead, overridable for anyone who puts it elsewhere.
MY_STUFF="${MY_STUFF:-/home/root/my_stuff}"
cd "$MY_STUFF" || { echo "boot_kernel: no $MY_STUFF" >&2; exit 1; }

# Only look for the env file if the values are not already in the environment
# -- which they are in invocation 1, where tv-env.sh was concatenated ahead of
# this script.
if [ -z "${TV_ETHADDR:-}" ]; then
	ENV_FILE="${TV_ENV:-$MY_STUFF/tv-env.sh}"
	if [ -r "$ENV_FILE" ]; then
		. "$ENV_FILE"
	else
		echo "boot_kernel: no values in the environment and no $ENV_FILE" >&2
		echo "boot_kernel: either pipe both files:" >&2
		echo "    cat tv-env.sh boot_kernel.sh | ssh root@<tv> \"bash -s\"" >&2
		echo "boot_kernel: or copy tv-env.sh to $MY_STUFF" >&2
		exit 1
	fi
fi

# Fail loudly rather than booting with an empty ethaddr= or serialNum=, which
# the LG drivers accept and then misbehave in ways that look like our bugs.
for v in TV_ETHADDR TV_SERIAL TV_MODEL TV_SBKEY TV_TOOLOPT TV_AVSINFO \
         TV_CPU_AVS TV_CORE_AVS TV_REGUL TV_MODELOPT TV_HWOPT TV_CHIP \
         TV_SVER TV_BVER TV_EMMC_SIZE TV_COUNTRYGRP TV_TVREGION \
         TV_PQE_TOOL TV_PQE_YEAR TV_REV; do
	eval "val=\${$v:-}"
	[ -n "$val" ] || { echo "boot_kernel: $v is unset in $ENV_FILE" >&2; exit 1; }
done

# ---------------------------------------------------------------- our arguments
# micom_pet=on          pets the MICOM watchdog, which otherwise resets the TV
#                       about 22 s after kexec
# kdrv_skip=GPU_Init    leaves 0xC4250000 unclaimed so panfrost can bind to
#                       gpu@c4250000 instead of LG's kbase
# initcall_blacklist=   keeps the SoC watchdog driver out of the way
# loglevel=4            NOT ignore_loglevel. With ignore_loglevel every printk
#                       is clocked out of ttyAMA0 at 115200 (~10 ms a line) and
#                       the kernel blocks on it even with nothing attached --
#                       it wedges the box under verbose logging and inflates
#                       every latency measurement. dmesg still records all of it.
# root=LABEL=           must match LABEL in alpine/config.sh
# dispopts=skipfw       display bring-up without reloading firmware
OURS="kdrv_skip=GPU_Init micom_pet=on initcall_blacklist=wdt_detect_init loglevel=4"
OURS="$OURS osd.disp.bosd=3860x2170 osd.disp.sosd=3860x2170"
OURS="$OURS root=LABEL=alpineroot dispopts=skipfw rootwait devtmpfs.mount=1"
OURS="$OURS vmalloc=624M hma=148M@0x06a000000;416M@0x077800000;104M@0x096c00000"
OURS="$OURS lg1k.use_vmap=1 hma.use_vmap=1 use_vmap=1 cma_on"
OURS="$OURS console=ttyAMA0,115200n81 debugMode=5 portProtection"
OURS="$OURS usbcore.wisa=1 usbcore.autosuspend=-1 skew_tick=1 cgroup.memory=nokmem"

# ------------------------------------------------------- this set's own values
UNIT="ethaddr=$TV_ETHADDR serialNum=$TV_SERIAL modelName=$TV_MODEL"
UNIT="$UNIT sbkey=$TV_SBKEY ToolOpt=$TV_TOOLOPT"
UNIT="$UNIT lg1k.o22_avsinfo=$TV_AVSINFO lg1k.o22_cpu_avs=$TV_CPU_AVS"
UNIT="$UNIT lg1k.o22_core_avs=$TV_CORE_AVS lg1k.o22_regul=$TV_REGUL"
UNIT="$UNIT modelopt=$TV_MODELOPT hwopt=$TV_HWOPT chip=$TV_CHIP"
UNIT="$UNIT sver=$TV_SVER bver=$TV_BVER emmc_size=$TV_EMMC_SIZE"
UNIT="$UNIT countryGrp=$TV_COUNTRYGRP tvregion=$TV_TVREGION"
UNIT="$UNIT pqe.tool=$TV_PQE_TOOL pqe.year=$TV_PQE_YEAR rev=$TV_REV"

CMDLINE="$OURS $UNIT"

# ---------------------------------------------------------------------- load
until ./kexec --no-checks \
	-l "$MY_STUFF/Image" \
	--initrd="$MY_STUFF/boot-initramfs.cpio.gz" \
	--dtb="$MY_STUFF/tv.dtb" \
	--command-line="$CMDLINE"
do
	echo "Retrying kernel load"
done

echo wdt_detect > /sys/bus/platform/drivers/wdt-detect/unbind

# enable logging
echo 8 > /proc/sys/kernel/printk

insmod fix_stuck_cpus.ko

echo 0 > /proc/lg/pm/mp_enable
for i in 1 2 3; do echo 0 > /sys/devices/system/cpu/cpu$i/online; done
echo "    online: $(cat /sys/devices/system/cpu/online)"

# dmesg
stty -F /dev/ttyAMA0 115200
printf "Running kexec\n" > /dev/ttyAMA0

./kexec -e
