obj-m += fix_stuck_cpus.o
obj-m += disable_arch_timer.o

# Point this at a kernel build tree configured with the extracted stock
# .config, at the exact release version reported by the running stock
# kernel (from the crash log: 5.4.268-320). vermagic must match that
# string for the module to load, since CONFIG_MODVERSIONS is off and
# CONFIG_MODULE_SIG is off on this kernel (loose match, no signing).
KDIR := /mnt/storage/SIC_O22_webOS23/kernel/linux-5.4-lg115x
PWD  := $(shell pwd)

# Where the finished modules land, next to the other build outputs.
#
# Kbuild builds external modules in the source directory and 5.4 offers no
# way to redirect that -- KBUILD_EXTMOD_OUTPUT arrived in 6.x. So the object
# files are still produced here and the .ko files are copied out afterwards.
# `make clean` removes both copies.
OUTDIR ?= $(abspath $(PWD)/../../build/modules)
KOS    := $(patsubst %.o,%.ko,$(obj-m))

# Nothing below adds a target name of its own: this file is included by
# Kbuild during the M= build, where defining `modules` or `install` would
# collide with the kernel's own targets.
all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
	mkdir -p $(OUTDIR)
	cp $(KOS) $(OUTDIR)/
	@echo "modules -> $(OUTDIR): $(KOS)"

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f $(addprefix $(OUTDIR)/,$(KOS))
