obj-m += fix_stuck_cpus.o
obj-m += disable_arch_timer.o

# Point this at a kernel build tree configured with the extracted stock
# .config, at the exact release version reported by the running stock
# kernel (from the crash log: 5.4.268-320). vermagic must match that
# string for the module to load, since CONFIG_MODVERSIONS is off and
# CONFIG_MODULE_SIG is off on this kernel (loose match, no signing).
KDIR := /mnt/storage/SIC_O22_webOS23/kernel/linux-5.4-lg115x
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
