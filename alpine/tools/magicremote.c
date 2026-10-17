// SPDX-License-Identifier: GPL-2.0
/*
 * magicremote - turn an LG Magic Remote (MR22N) into a normal input device.
 *
 * The remote pairs as BLE HID, but its report descriptor declares no usages
 * at all -- three Consumer Control collections carrying opaque byte arrays.
 * hid-generic therefore registers hidraw only and no evdev node, so nothing
 * in userspace sees the buttons. LG decode this in webOS; we do it here.
 *
 * Report 0xFD, 20 bytes:
 *
 *   [0]      0xfd   report ID
 *   [1]      ?      varies (flags? link quality?)
 *   [2]      seq    +1 per packet, ~10ms
 *   [3]      0xfd   LG's own type marker
 *   [4]      0x01   subtype
 *   [5..16]  motion, believed 6 x int16 big-endian (gyro xyz + accel xyz)
 *   [17]     0x80 on key press, 0x00 on release
 *   [18]     key code (see table below) -- LG's long-standing IR code set
 *   [19]     wheel, signed int8: +1 up, -1 down
 *
 * There is no key-up code: release is signalled by [17] and [18] going to
 * zero, so we remember what is down and release that.
 *
 *   ./magicremote            find the remote automatically
 *   ./magicremote /dev/hidraw2
 *
 * Runs until killed. The remote sleeps when idle and its hidraw node goes
 * away with it, so the device is reopened as often as needed; the uinput
 * device is created once and kept, so whatever is holding it open (kwin,
 * libinput) does not see the keyboard disappear and come back.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>

/* KEY_ASSISTANT arrived in 4.13; fall back if the uapi headers predate it. */
#ifndef KEY_ASSISTANT
#define KEY_ASSISTANT KEY_FN_F2
#endif

struct keymap { unsigned char code; unsigned short key; const char *name; };

static const struct keymap keymap[] = {
	{ 0x10, KEY_0,            "0" },
	{ 0x11, KEY_1,            "1" },
	{ 0x12, KEY_2,            "2" },
	{ 0x13, KEY_3,            "3" },
	{ 0x14, KEY_4,            "4" },
	{ 0x15, KEY_5,            "5" },
	{ 0x16, KEY_6,            "6" },
	{ 0x17, KEY_7,            "7" },
	{ 0x18, KEY_8,            "8" },
	{ 0x19, KEY_9,            "9" },
	{ 0xab, KEY_EPG,          "guide" },
	{ 0x45, KEY_CONTEXT_MENU, "more" },
	{ 0x02, KEY_VOLUMEUP,     "vol+" },
	{ 0x03, KEY_VOLUMEDOWN,   "vol-" },
	{ 0x09, KEY_MUTE,         "mute" },
	{ 0x00, KEY_CHANNELUP,    "ch+" },
	{ 0x01, KEY_CHANNELDOWN,  "ch-" },
	{ 0x7c, KEY_HOMEPAGE,     "home" },
	{ 0x8b, KEY_VOICECOMMAND, "mic" },
	{ 0x0b, KEY_VIDEO,        "input" },
	{ 0x40, KEY_UP,           "up" },
	{ 0x41, KEY_DOWN,         "down" },
	{ 0x07, KEY_LEFT,         "left" },
	{ 0x06, KEY_RIGHT,        "right" },
	{ 0x44, KEY_ENTER,        "ok" },
	{ 0x28, KEY_BACK,         "back" },
	{ 0x43, KEY_CONFIG,       "settings" },
	{ 0x72, KEY_RED,          "red" },
	{ 0x71, KEY_GREEN,        "green" },
	{ 0x63, KEY_YELLOW,       "yellow" },
	{ 0x61, KEY_BLUE,         "blue" },

	/* App shortcut buttons. No standard evdev codes exist for these, so
	 * they get spare KEY_PROG and KEY_FN codes -- bind them to whatever
	 * you like in the compositor. */
	{ 0x56, KEY_PROG1,        "netflix" },
	{ 0x5c, KEY_PROG2,        "prime video" },
	{ 0x31, KEY_PROG3,        "disney+" },
	{ 0x49, KEY_PROG4,        "rakuten tv" },
	{ 0x05, KEY_ASSISTANT,    "google assistant" },
	{ 0x0c, KEY_FN_F1,        "alexa" },
};
#define NKEYS ((int)(sizeof(keymap) / sizeof(keymap[0])))

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

/* Find the hidraw node whose HID_NAME looks like a Magic Remote. */
static int find_remote(char *out, size_t outsz)
{
	DIR *d = opendir("/sys/class/hidraw");
	struct dirent *e;
	int found = 0;

	if (!d) return 0;
	while (!found && (e = readdir(d))) {
		char path[512], line[512];
		FILE *f;

		if (strncmp(e->d_name, "hidraw", 6)) continue;
		snprintf(path, sizeof(path), "/sys/class/hidraw/%s/device/uevent", e->d_name);
		f = fopen(path, "r");
		if (!f) continue;
		while (fgets(line, sizeof(line), f)) {
			if (!strstr(line, "HID_NAME=")) continue;
			if (strstr(line, "MR22") || strstr(line, "Magic") ||
			    strstr(line, "MR21") || strstr(line, "MR23")) {
				snprintf(out, outsz, "/dev/%s", e->d_name);
				found = 1;
			}
		}
		fclose(f);
	}
	closedir(d);
	return found;
}

static int uinput_open(void)
{
	struct uinput_setup us;
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);

	if (fd < 0) { perror("/dev/uinput"); return -1; }

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_EVBIT, EV_REL);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	ioctl(fd, UI_SET_EVBIT, EV_REP);        /* let the kernel auto-repeat */
	ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
	for (int i = 0; i < NKEYS; i++)
		ioctl(fd, UI_SET_KEYBIT, keymap[i].key);

	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_BLUETOOTH;
	us.id.vendor  = 0x000f;                 /* as reported by HoG */
	us.id.product = 0x3412;
	snprintf(us.name, sizeof(us.name), "LG Magic Remote");

	if (ioctl(fd, UI_DEV_SETUP, &us) < 0) { perror("UI_DEV_SETUP"); return -1; }
	if (ioctl(fd, UI_DEV_CREATE) < 0)     { perror("UI_DEV_CREATE"); return -1; }
	return fd;
}

static void emit(int fd, int type, int code, int val)
{
	struct input_event ev = { .type = type, .code = code, .value = val };
	if (write(fd, &ev, sizeof(ev)) != sizeof(ev))
		perror("write uinput");
}

static void sync_now(int fd) { emit(fd, EV_SYN, SYN_REPORT, 0); }

int main(int argc, char **argv)
{
	char path[300];
	int verbose = !!getenv("MAGICREMOTE_VERBOSE");

	/* An explicit path is honoured as given; otherwise the node is looked
	 * up by HID name each time, since the number changes between
	 * reconnects. */
	int explicit_path = argc > 1;
	if (explicit_path)
		snprintf(path, sizeof(path), "%s", argv[1]);

	int ui = uinput_open();
	if (ui < 0) return 1;

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	unsigned char buf[64];
	unsigned short down = 0;          /* key currently held, 0 if none */
	int waiting_logged = 0;

	/* Outer loop: (re)acquire the hidraw node. The remote powers down when
	 * idle and takes its node with it, so losing the device is normal and
	 * not an error. */
	while (!stop) {
		if (!explicit_path && !find_remote(path, sizeof(path))) {
			if (!waiting_logged) {
				fprintf(stderr, "magicremote: waiting for remote\n");
				waiting_logged = 1;
			}
			sleep(2);
			continue;
		}

		int hid = open(path, O_RDONLY);
		if (hid < 0) {
			if (!waiting_logged) {
				fprintf(stderr, "magicremote: waiting for %s (%s)\n",
					path, strerror(errno));
				waiting_logged = 1;
			}
			sleep(2);
			continue;
		}

		fprintf(stderr, "magicremote: %s -> uinput\n", path);
		waiting_logged = 0;

	while (!stop) {
		ssize_t n = read(hid, buf, sizeof(buf));
		if (n < 0) {
			if (errno == EINTR) continue;
			break;                    /* device went away */
		}
		if (n == 0) break;                /* EOF: disconnected */
		if (n < 20 || buf[0] != 0xfd) continue;

		/* wheel: relative, independent of the key field */
		signed char wheel = (signed char)buf[19];
		if (wheel) {
			emit(ui, EV_REL, REL_WHEEL, wheel);
			sync_now(ui);
			if (verbose) fprintf(stderr, "wheel %+d\n", wheel);
		}

		if (buf[17] == 0x80) {
			unsigned short key = 0;
			const char *name = "?";
			for (int i = 0; i < NKEYS; i++)
				if (keymap[i].code == buf[18]) {
					key = keymap[i].key;
					name = keymap[i].name;
					break;
				}
			if (!key) {
				if (verbose)
					fprintf(stderr, "unmapped code 0x%02x\n", buf[18]);
				continue;
			}
			if (down == key) continue;       /* still held */
			if (down) { emit(ui, EV_KEY, down, 0); sync_now(ui); }
			emit(ui, EV_KEY, key, 1);
			sync_now(ui);
			down = key;
			if (verbose) fprintf(stderr, "press %s (0x%02x)\n", name, buf[18]);
		} else if (down && buf[17] == 0x00 && buf[18] == 0x00) {
			emit(ui, EV_KEY, down, 0);
			sync_now(ui);
			if (verbose) fprintf(stderr, "release\n");
			down = 0;
		}
		}   /* inner read loop */

		close(hid);
		/* Do not leave a key stuck down across a disconnect. */
		if (down) { emit(ui, EV_KEY, down, 0); sync_now(ui); down = 0; }
		if (!stop) {
			fprintf(stderr, "magicremote: disconnected\n");
			sleep(2);
		}
	}   /* outer reconnect loop */

	if (down) { emit(ui, EV_KEY, down, 0); sync_now(ui); }
	ioctl(ui, UI_DEV_DESTROY);
	return 0;
}
