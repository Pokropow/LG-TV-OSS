/*
 * audfwload - load firmware into the LG o22 audio DSPs via the kdriver's
 *             fwload character devices.
 *
 * On stock webOS this is done by systemd calling LG's own `fwloader`. Nothing
 * in a custom userspace does it, so the four DSPs stay halted: /proc/mcu/audN
 * lists no images, core/aud/dsp_control.c's fwload_get_dsp_memory_info(name,
 * "ram", ...) fails, and ALSA playback dies early -- the symptom is
 *
 *     lgsic-aplayback lgsic-aplayback: ASoC: can't open component ...: -5
 *
 * which comes from _aplayback_connect() -> bm_create_block("renderer") in
 * alsa_playback.c, i.e. the driver trying to build a pipeline inside a DSP
 * that is not running.
 *
 * The firmware already loaded by stock before a kexec cannot be reused: the
 * audio driver looks the image up through fwload's own registry (empty in a
 * fresh kernel) and resets/halts the DSPs itself during normal operation.
 * So the blobs have to be pushed in again from userspace -- same firmware
 * files as stock uses, just loaded by us.
 *
 * Protocol, per device, from kdriver/core/fwload/fwload.h:
 *
 *   FWLOAD_IOCTL_CONFIG   register image <name> -> <path>. Does NOT read the
 *                         file; it only records the mapping (set_image_filename).
 *   FWLOAD_IOCTL_RUN      reset_run(): the kernel reads each registered image
 *                         with kernel_read_file_from_path(), copies it to the
 *                         DSP's HMA area and starts the core.
 *   FWLOAD_IOCTL_RESET    hw_reset()
 *   FWLOAD_IOCTL_HALT     hold/release the core
 *
 * Note the kernel opens the path itself, so it must be readable from the
 * kernel's point of view -- an absolute path on a real mount, not something
 * only visible to this process.
 *
 * o22 has four DSPs, each taking a "rom" and a "ram" image. Expected sizes
 * from fwload_aud.c (rom_sizes/ram_sizes), useful as a sanity check:
 *
 *   dsp   rom         ram
 *   0     0x0780000   0x1380000
 *   1     0x0600000   0x0d00000
 *   2     0x0400000   0x0d00000
 *   3     0x0500000   0x0a80000
 *
 * Build (on the TV, or cross):
 *   gcc -O2 -Wall -o audfwload audfwload.c
 *
 * Usage:
 *   audfwload /dev/fwload_aud0 rom:/lib/firmware/<rom> ram:/lib/firmware/<ram>
 *   audfwload -n /dev/fwload_aud0 rom:...     # stage only, do not RUN
 *   audfwload --halt   /dev/fwload_aud0
 *   audfwload --reset  /dev/fwload_aud0
 *
 * Check the result with:
 *   cat /proc/mcu/aud0/status      # should now list the images
 *   ls  /proc/mcu/aud0/image/
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Must match kdriver/core/fwload/fwload.h exactly -- the struct size is
 * encoded into the ioctl number, so a layout mismatch fails with ENOTTY
 * rather than doing something subtly wrong. 32 + 8 + 4 + 4 = 48 on LP64. */
struct fwload_image {
	char name[32];
	union {
		const char *filename;
		unsigned int compat_data;
		unsigned long long sizer;
	};
	unsigned int length;	/* strlen(filename) + 1 */
	unsigned int size;	/* image size; stored as backup_size */
};

#define FWLOAD_IOCTL_TYPE	'F'
#define FWLOAD_IOCTL_RESET	_IO(FWLOAD_IOCTL_TYPE, 1)
#define FWLOAD_IOCTL_HALT	_IO(FWLOAD_IOCTL_TYPE, 2)
#define FWLOAD_IOCTL_CONFIG	_IOW(FWLOAD_IOCTL_TYPE, 3, struct fwload_image)
#define FWLOAD_IOCTL_RUN	_IO(FWLOAD_IOCTL_TYPE, 5)

static int config_image(int fd, const char *name, const char *path)
{
	struct fwload_image img;
	struct stat st;

	if (stat(path, &st) < 0) {
		fprintf(stderr, "audfwload: %s: %s\n", path, strerror(errno));
		return -1;
	}
	if (!S_ISREG(st.st_mode)) {
		fprintf(stderr, "audfwload: %s: not a regular file\n", path);
		return -1;
	}

	memset(&img, 0, sizeof(img));
	snprintf(img.name, sizeof(img.name), "%s", name);
	img.filename = path;
	img.length = (unsigned int)strlen(path) + 1;
	img.size = (unsigned int)st.st_size;

	if (ioctl(fd, FWLOAD_IOCTL_CONFIG, &img) < 0) {
		fprintf(stderr, "audfwload: CONFIG %s=%s: %s\n",
			name, path, strerror(errno));
		return -1;
	}

	printf("  staged %-4s %s (%lld bytes)\n",
	       name, path, (long long)st.st_size);
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: audfwload [-n] <device> <name>:<path> [<name>:<path>...]\n"
		"       audfwload --halt|--release|--reset <device>\n"
		"\n"
		"  -n          stage images but do not RUN\n"
		"  --halt      hold the core halted\n"
		"  --release   release the halt\n"
		"  --reset     hardware reset\n"
		"\n"
		"example:\n"
		"  audfwload /dev/fwload_aud0 rom:/lib/firmware/aud0.rom \\\n"
		"                             ram:/lib/firmware/aud0.ram\n");
	exit(2);
}

int main(int argc, char **argv)
{
	int fd, i, rc = 0, no_run = 0, staged = 0;
	const char *dev;
	unsigned long simple_cmd = 0;
	unsigned long simple_arg = 0;

	if (argc < 3)
		usage();

	i = 1;
	if (!strcmp(argv[i], "-n")) {
		no_run = 1;
		i++;
	} else if (!strcmp(argv[i], "--halt")) {
		simple_cmd = FWLOAD_IOCTL_HALT;
		simple_arg = 1;
		i++;
	} else if (!strcmp(argv[i], "--release")) {
		simple_cmd = FWLOAD_IOCTL_HALT;
		simple_arg = 0;
		i++;
	} else if (!strcmp(argv[i], "--reset")) {
		simple_cmd = FWLOAD_IOCTL_RESET;
		simple_arg = 1;
		i++;
	}

	if (i >= argc)
		usage();
	dev = argv[i++];

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "audfwload: %s: %s\n", dev, strerror(errno));
		return 1;
	}

	if (simple_cmd) {
		if (ioctl(fd, simple_cmd, simple_arg) < 0) {
			fprintf(stderr, "audfwload: ioctl on %s: %s\n",
				dev, strerror(errno));
			rc = 1;
		}
		close(fd);
		return rc;
	}

	if (i >= argc) {
		fprintf(stderr, "audfwload: no images given\n");
		close(fd);
		usage();
	}

	printf("%s:\n", dev);
	for (; i < argc; i++) {
		char *spec = argv[i];
		char *sep = strchr(spec, ':');

		if (!sep || sep == spec || !sep[1]) {
			fprintf(stderr,
				"audfwload: bad image spec '%s', want <name>:<path>\n",
				spec);
			rc = 1;
			continue;
		}

		*sep = '\0';
		if (config_image(fd, spec, sep + 1) < 0)
			rc = 1;
		else
			staged++;
		*sep = ':';
	}

	if (rc) {
		fprintf(stderr, "audfwload: not running the DSP after errors\n");
		close(fd);
		return 1;
	}

	if (no_run) {
		printf("  %d image(s) staged, RUN skipped (-n)\n", staged);
		close(fd);
		return 0;
	}

	/* The kernel reads every staged file here, copies it into the DSP's
	 * HMA area and releases the core. A failure at this point is usually
	 * either an unreadable path or a missing/undersized HMA pool
	 * (audio_buffer0 on o22) -- dmesg will say which. */
	if (ioctl(fd, FWLOAD_IOCTL_RUN, 0) < 0) {
		fprintf(stderr, "audfwload: RUN: %s\n", strerror(errno));
		fprintf(stderr, "audfwload: check dmesg; see /proc/mcu/*/status\n");
		rc = 1;
	} else {
		printf("  running (%d image(s) loaded)\n", staged);
	}

	close(fd);
	return rc;
}
