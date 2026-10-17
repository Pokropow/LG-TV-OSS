// SPDX-License-Identifier: GPL-2.0
/*
 * hidcap - find the signal in an LG Magic Remote's HID reports.
 *
 * The MR22N's report descriptor declares no usages at all -- three Consumer
 * Control collections carrying opaque byte arrays (report IDs 0xFD/0xF9/0xFE).
 * hid-generic therefore registers no input device and the payload has to be
 * decoded by hand.
 *
 * The difficulty is that the motion sensor streams continuously, so every
 * report differs from the last and a naive diff shows everything. Instead:
 * learn what each byte position does while the remote is idle, then report
 * only bytes that leave that range.
 *
 *   ./hidcap -s /dev/hidraw2         which report IDs arrive, and how often
 *   ./hidcap -l 5 /dev/hidraw2       learn 5s of idle, then show deviations
 *   ./hidcap -l 5 -m 8 /dev/hidraw2  ...with a tolerance of +/-8 per byte
 *   ./hidcap -a /dev/hidraw2         dump everything, no filtering
 *   ./hidcap -w 16:18 /dev/hidraw2   watch only these byte offsets, print
 *                                    hex + binary whenever they change
 *
 * Typical use: run with -l 5, keep the remote flat and still and touch
 * nothing while it learns, then press one button at a time.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_REPORT	256
#define MAX_IDS		256

static unsigned char lo[MAX_IDS][MAX_REPORT];	/* learned min per byte */
static unsigned char hi[MAX_IDS][MAX_REPORT];	/* learned max per byte */
static int	      seen[MAX_IDS];		/* reports seen per ID    */
static int	      rlen[MAX_IDS];		/* report length per ID   */
static unsigned long count[MAX_IDS];

static int excl[MAX_IDS], only[MAX_IDS], have_only;
static int watch_lo = -1, watch_hi = -1;
static unsigned char wprev[MAX_IDS][MAX_REPORT];
static int wseen[MAX_IDS];
static volatile sig_atomic_t stop;

static void on_sigint(int s) { (void)s; stop = 1; }

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void usage(const char *me)
{
	fprintf(stderr,
	 "usage: %s [-s] [-l SEC] [-m MARGIN] [-a] [-x ID] [-o ID] /dev/hidrawN\n"
	 "  -s        stats only: report ID histogram, once a second\n"
	 "  -l SEC    learn idle byte ranges for SEC seconds, then show\n"
	 "            only bytes that fall outside them (default 5)\n"
	 "  -m N      widen the learned range by N either side\n"
	 "  -a        no filtering, print every report\n"
	 "  -x ID     exclude report ID (hex), repeatable\n"
	 "  -o ID     only this report ID (hex), repeatable\n"
	 "  -w A:B    watch only byte offsets A..B (raw offsets, where 0 is\n"
	 "            the report ID). Prints hex and binary on every change,\n"
	 "            ignoring all other bytes -- use this to isolate a button\n"
	 "            bitfield from a continuously streaming motion sensor.\n", me);
	exit(2);
}

int main(int argc, char **argv)
{
	int stats = 0, learn_s = 5, margin = 0, all = 0, opt;

	while ((opt = getopt(argc, argv, "sl:m:ax:o:w:h")) != -1) {
		switch (opt) {
		case 's': stats = 1; break;
		case 'l': learn_s = atoi(optarg); break;
		case 'm': margin = atoi(optarg); break;
		case 'a': all = 1; break;
		case 'w': {
			char *c = strchr(optarg, ':');
			if (!c) usage(argv[0]);
			watch_lo = atoi(optarg);
			watch_hi = atoi(c + 1);
			if (watch_lo < 0 || watch_hi < watch_lo) usage(argv[0]);
			break;
		}
		case 'x': excl[strtoul(optarg, NULL, 16) & 0xff] = 1; break;
		case 'o': only[strtoul(optarg, NULL, 16) & 0xff] = 1; have_only = 1; break;
		default: usage(argv[0]);
		}
	}
	if (optind >= argc) usage(argv[0]);

	int fd = open(argv[optind], O_RDONLY);
	if (fd < 0) { perror(argv[optind]); return 1; }
	signal(SIGINT, on_sigint);

	unsigned char buf[MAX_REPORT];
	double t0 = now_s(), learn_until = t0 + learn_s, next_stat = t0 + 1.0;
	int learning = !stats && !all;

	if (learning)
		fprintf(stderr, "learning idle ranges for %ds -- keep the remote "
				"still and press nothing\n", learn_s);
	else if (stats)
		fprintf(stderr, "counting report IDs, ^C to stop\n");

	while (!stop) {
		ssize_t n = read(fd, buf, sizeof(buf));
		if (n <= 0) { if (errno == EINTR) continue; perror("read"); break; }

		int id = buf[0];
		if (excl[id] || (have_only && !only[id])) continue;

		count[id]++;
		double t = now_s();

		if (stats) {
			if (t >= next_stat) {
				next_stat = t + 1.0;
				fprintf(stderr, "[%6.1f] ", t - t0);
				for (int i = 0; i < MAX_IDS; i++)
					if (count[i])
						fprintf(stderr, "id %02x: %-8lu ", i, count[i]);
				fputc('\n', stderr);
			}
			continue;
		}

		if (watch_lo >= 0) {
			/* Compare only the watched window. The motion bytes
			 * change every packet, so anything that includes them
			 * would print continuously and tell you nothing. */
			int hi_b = watch_hi < n ? watch_hi : (int)n - 1;
			int changed = !wseen[id];
			for (int i = watch_lo; i <= hi_b && !changed; i++)
				if (wprev[id][i] != buf[i]) changed = 1;
			if (!changed) continue;

			printf("[%8.3f] id=%02x  ", t - t0, id);
			for (int i = watch_lo; i <= hi_b; i++)
				printf("%d:%02x ", i, buf[i]);
			printf(" bits:");
			for (int i = watch_lo; i <= hi_b; i++) {
				putchar(' ');
				for (int b = 7; b >= 0; b--)
					putchar((buf[i] >> b) & 1 ? '1' : '0');
			}
			putchar('\n');
			fflush(stdout);

			memcpy(wprev[id], buf, n);
			wseen[id] = 1;
			continue;
		}

		if (all) {
			printf("[%8.3f] id=%02x len=%zd ", t - t0, id, n);
			for (ssize_t i = 0; i < n; i++) printf(" %02x", buf[i]);
			putchar('\n');
			fflush(stdout);
			continue;
		}

		if (learning && t < learn_until) {
			/* widen this ID's per-byte range */
			if (!seen[id]) {
				memcpy(lo[id], buf, n);
				memcpy(hi[id], buf, n);
				rlen[id] = n;
			} else {
				for (ssize_t i = 0; i < n && i < rlen[id]; i++) {
					if (buf[i] < lo[id][i]) lo[id][i] = buf[i];
					if (buf[i] > hi[id][i]) hi[id][i] = buf[i];
				}
			}
			seen[id]++;
			continue;
		}

		if (learning) {
			learning = 0;
			fprintf(stderr, "\nlearned:\n");
			for (int i = 0; i < MAX_IDS; i++) {
				if (!seen[i]) continue;
				fprintf(stderr, "  id %02x  len %d  %d samples\n",
					i, rlen[i], seen[i]);
				fprintf(stderr, "    varying bytes:");
				int any = 0;
				for (int b = 1; b < rlen[i]; b++)
					if (hi[i][b] != lo[i][b]) {
						fprintf(stderr, " %d", b);
						any = 1;
					}
				if (!any) fprintf(stderr, " (none -- all constant)");
				fputc('\n', stderr);
			}
			fprintf(stderr, "\nnow press one button at a time\n\n");
		}

		/* Print only if some byte left its learned range. */
		if (!seen[id]) {
			printf("[%8.3f] id=%02x NEW (not seen while idle) len=%zd ",
			       t - t0, id, n);
			for (ssize_t i = 1; i < n; i++) printf(" %02x", buf[i]);
			putchar('\n');
			fflush(stdout);
			continue;
		}

		int dev = 0;
		for (ssize_t i = 1; i < n && i < rlen[id]; i++) {
			int l = lo[id][i] - margin, h = hi[id][i] + margin;
			if (buf[i] < l || buf[i] > h) { dev = 1; break; }
		}
		if (!dev) continue;

		printf("[%8.3f] id=%02x ", t - t0, id);
		for (ssize_t i = 1; i < n && i < rlen[id]; i++) {
			int l = lo[id][i] - margin, h = hi[id][i] + margin;
			int out = buf[i] < l || buf[i] > h;
			printf(out ? "[%02x]" : " %02x ", buf[i]);
		}
		putchar('\n');
		fflush(stdout);
	}

	fprintf(stderr, "\ntotals: ");
	for (int i = 0; i < MAX_IDS; i++)
		if (count[i]) fprintf(stderr, "id %02x: %lu  ", i, count[i]);
	fputc('\n', stderr);
	return 0;
}
