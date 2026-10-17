# tv-env.example.sh - per-unit values for boot_kernel.sh.
#
# Copy to tv-env.sh and fill in from YOUR set. tv-env.sh is gitignored; this
# example is not, so keep real values out of it.
#
#     cp tv-env.example.sh tv-env.sh
#     $EDITOR tv-env.sh
#
# Every value below comes from the stock kernel's own command line. Read it on
# the TV while booted into stock webOS:
#
#     cat /proc/cmdline | tr ' ' '\n'
#
# and copy each field across. boot_kernel.sh supplies everything else -- the
# arguments that are ours rather than the set's -- so this file is the only
# thing that has to change to move the project to another TV.
#
# WHY THIS IS SPLIT OUT: several of these identify one physical television.
# ethaddr is its MAC address and serialNum its service serial; ToolOpt, the AVS
# values and sbkey are per-unit silicon calibration and key data. They do not
# belong in a public repository.

# --- identity -----------------------------------------------------------------
TV_ETHADDR="AA:BB:CC:DD:EE:FF"       # ethaddr=
TV_SERIAL="000XXXX00000"             # serialNum=
TV_MODEL="OLED65C21LA"               # modelName=

# --- per-unit silicon / keys --------------------------------------------------
TV_SBKEY="0x00000000"                # sbkey=
TV_TOOLOPT="0:0:0:0:0:0"             # ToolOpt=
TV_AVSINFO="0x000000"                # lg1k.o22_avsinfo=
TV_CPU_AVS="0x0"                     # lg1k.o22_cpu_avs=
TV_CORE_AVS="0x0"                    # lg1k.o22_core_avs=
TV_REGUL="0x0"                       # lg1k.o22_regul=

# --- model / region options ---------------------------------------------------
TV_MODELOPT="00000000000000"         # modelopt=
TV_HWOPT="000000000000000000"        # hwopt=
TV_CHIP="O22A2"                      # chip=
TV_SVER="4.07.19"                    # sver=
TV_BVER="4.07.19"                    # bver=
TV_EMMC_SIZE="0x1d2000000"           # emmc_size=
TV_COUNTRYGRP="4"                    # countryGrp=
TV_TVREGION="DVB"                    # tvregion=
TV_PQE_TOOL="C2"                     # pqe.tool=
TV_PQE_YEAR="22"                     # pqe.year=
TV_REV="1"                           # rev=
