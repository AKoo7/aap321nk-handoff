/* idu_tool — static helper (no libc-on-squashfs dependency) for the TZ hand-off.
 *   stage  : /dev/mem-write the arm64 image / DTB / descriptor to their PAs
 *   verify : read back a few pages of each and check they landed
 *   fire   : finit_module() the spliced .ko (payload does flush+IRQ-mask+SMC)
 *   heal   : sync + drop_caches (recover a clobbered page cache)
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/syscall.h>
#include <linux/input.h>

/* btn <secs>: poll all input devices; exit 1 if any key was pressed (physical disarm
 * escape: hold WPS during boot -> boot stock), exit 0 if none, exit 2 if no input dev. */
static int btn_mode(int secs)
{
	struct input_event ev;
	int fds[16], n = 0, i, seen = 0;
	char path[64];
	time_t end;
	for (i = 0; i < 16; i++) {
		snprintf(path, sizeof path, "/dev/input/event%d", i);
		int f = open(path, O_RDONLY | O_NONBLOCK);
		if (f >= 0) fds[n++] = f;
	}
	if (!n) { fprintf(stderr, "btn: no input devices\n"); return 2; }
	printf("btn: watching %d input device(s) for %d s\n", n, secs);
	end = time(NULL) + secs;
	while (time(NULL) < end) {
		for (i = 0; i < n; i++)
			while (read(fds[i], &ev, sizeof ev) == (ssize_t)sizeof ev)
				if (ev.type == EV_KEY && ev.value == 1) {
					printf("btn: keycode %d pressed -> boot stock\n", ev.code);
					seen = 1;
				}
		usleep(150000);
	}
	return seen ? 1 : 0;
}

#define IMG_FILE "/tmp/owrt_Image"
#define DTB_FILE "/tmp/owrt_mem.dtb"
#define DSC_FILE "/tmp/desc_blob.bin"
#define IMG_PA 0x44000000ULL
#define DTB_PA 0x48C00000ULL
#define DSC_PA 0x48D00000ULL

static int stage_one(const char *src, unsigned long long pa)
{
	int f = open("/dev/mem", O_RDWR), s = open(src, O_RDONLY);
	char buf[1 << 16];
	ssize_t n;
	unsigned long long total = 0;
	if (f < 0) { perror("open /dev/mem"); return 1; }
	if (s < 0) { perror(src); close(f); return 1; }
	if (lseek(f, (off_t)pa, SEEK_SET) < 0) { perror("lseek"); return 1; }
	while ((n = read(s, buf, sizeof buf)) > 0) {
		if (write(f, buf, n) != n) { perror("write /dev/mem"); return 1; }
		total += n;
	}
	close(s); close(f);
	printf("staged %-22s -> %#llx  %llu bytes\n", src, pa, total);
	return 0;
}

static int verify_one(const char *name, unsigned long long pa, const char *src)
{
	int f = open("/dev/mem", O_RDONLY), s = open(src, O_RDONLY);
	char a[4096], b[4096];
	ssize_t n;
	if (f < 0 || s < 0) { perror("open"); return 1; }
	if (lseek(f, (off_t)pa, SEEK_SET) < 0) { perror("lseek"); return 1; }
	n = read(s, b, sizeof b);
	if (read(f, a, n) != n) { perror("read /dev/mem"); return 1; }
	printf("%-14s %#llx: %s\n", name, pa, memcmp(a, b, n) ? "MISMATCH" : "ok");
	close(f); close(s);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: %s stage|verify|fire [ko]|heal\n", argv[0]); return 2; }

	if (!strcmp(argv[1], "stage")) {
		int r = stage_one(IMG_FILE, IMG_PA);
		r |= stage_one(DTB_FILE, DTB_PA);
		r |= stage_one(DSC_FILE, DSC_PA);
		return r;
	}
	if (!strcmp(argv[1], "verify")) {
		int r = verify_one("image", IMG_PA, IMG_FILE);
		r |= verify_one("dtb", DTB_PA, DTB_FILE);
		r |= verify_one("descriptor", DSC_PA, DSC_FILE);
		return r;
	}
	if (!strcmp(argv[1], "fire")) {
		const char *ko = argc > 2 ? argv[2] : "/tmp/pty_owrt2.ko";
		int fd = open(ko, O_RDONLY), r;
		if (fd < 0) { perror(ko); return 1; }
		r = (int)syscall(SYS_finit_module, fd, "", 0);
		printf("finit_module rc=%d errno=%d (%s)\n", r, errno, strerror(errno));
		return r;
	}
	if (!strcmp(argv[1], "heal")) {
		FILE *f;
		sync();
		f = fopen("/proc/sys/vm/drop_caches", "w");
		if (f) { fputs("3", f); fclose(f); }
		printf("heal: drop_caches done\n");
		return 0;
	}
	if (!strcmp(argv[1], "btn"))
		return btn_mode(argc > 2 ? atoi(argv[2]) : 2);
	fprintf(stderr, "unknown mode\n");
	return 2;
}
