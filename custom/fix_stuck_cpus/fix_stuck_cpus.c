#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>

typedef bool (*stuck_check_fn)(void);
typedef int (*patch_text_fn)(void *addr, u32 insn);

/* AArch64: "mov w0, #0" ; "ret" -- unconditionally return false (bool in w0). */
#define INSN_MOV_W0_0  0x52800000u
#define INSN_RET       0xd65f03c0u

static int __init fix_stuck_cpus_init(void)
{
	unsigned long func_addr;
	patch_text_fn patch_insn;
	int ret;

	func_addr = kallsyms_lookup_name("cpus_are_stuck_in_kernel");
	if (!func_addr) {
		pr_err("fix_stuck_cpus: cpus_are_stuck_in_kernel not found\n");
		return -ENOENT;
	}

	patch_insn = (patch_text_fn)kallsyms_lookup_name("aarch64_insn_patch_text_nosync");
	if (!patch_insn) {
		pr_err("fix_stuck_cpus: aarch64_insn_patch_text_nosync not found\n");
		return -ENOENT;
	}

	pr_info("fix_stuck_cpus: cpus_are_stuck_in_kernel at 0x%lx\n", func_addr);

	{
		stuck_check_fn check = (stuck_check_fn)func_addr;
		bool was_stuck = check();

		pr_info("fix_stuck_cpus: cpus_are_stuck_in_kernel() returned %s before patching\n",
			was_stuck ? "true" : "false");
	}

	ret = patch_insn((void *)func_addr, INSN_MOV_W0_0);
	if (ret) {
		pr_err("fix_stuck_cpus: patch of mov failed: %d\n", ret);
		return ret;
	}

	ret = patch_insn((void *)(func_addr + 4), INSN_RET);
	if (ret) {
		pr_err("fix_stuck_cpus: patch of ret failed: %d\n", ret);
		return ret;
	}

	pr_info("fix_stuck_cpus: patched cpus_are_stuck_in_kernel to always return false\n");

	return 0;
}

static void __exit fix_stuck_cpus_exit(void) {}

module_init(fix_stuck_cpus_init);
module_exit(fix_stuck_cpus_exit);
MODULE_LICENSE("GPL");
