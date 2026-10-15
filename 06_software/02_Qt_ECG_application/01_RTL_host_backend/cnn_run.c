/*
 * cnn_run -- send one ECG frame to the PL and read the logits back.
 *
 *   ./cnn_run <input.hex> [golden_logits.hex] [expected_label]
 *
 * Data path:  DDR --MM2S--> CNN_wrapper --S2MM--> DDR
 *
 * The register sequence mirrors kv260_hardware_platform's tb_system.sv, which
 * is the verified reference for this design. Two orderings there are load-
 * bearing and are kept:
 *
 *   1. S2MM is armed BEFORE the CNN is started, so the accelerator's output
 *      can never be back-pressured by an unconfigured receive channel.
 *   2. MM2S LENGTH is written LAST, because writing LENGTH is what launches
 *      the transfer.
 *
 * The AXI DMA is driven directly through /dev/mem rather than through the
 * kernel's dmaengine, so the whole path is visible in one file. That is safe
 * here because CONFIG_IO_STRICT_DEVMEM is not set on this kernel and nothing
 * else is issuing transfers on this channel.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>

/* ---- the design's address map (see tb_system.sv) ---- */
#define DMA_BASE      0x80010000UL
#define CNN_BASE      0x80020000UL
#define MAP_SIZE      0x10000UL

/* AXI DMA, simple (non-scatter-gather) mode */
#define MM2S_DMACR    0x00
#define MM2S_DMASR    0x04
#define MM2S_SA       0x18
#define MM2S_LENGTH   0x28
#define S2MM_DMACR    0x30
#define S2MM_DMASR    0x34
#define S2MM_DA       0x48
#define S2MM_LENGTH   0x58

#define DMACR_RUN     0x00000001u
#define DMACR_RESET   0x00000004u
#define DMACR_IOC_IRQ 0x00001000u
#define DMASR_IDLE    0x00000002u
#define DMASR_ERR_MSK 0x00000070u   /* DMAIntErr | DMASlvErr | DMADecErr */

/* CNN_wrapper AXI4-Lite (see CNN_wrapper.sv header comment) */
#define CNN_CTRL      0x00   /* W: bit0 start, bit1 clear done */
#define CNN_STATUS    0x04   /* R: bit0 done_sticky, bit1 idle, bit2 busy */
#define CNN_GIE       0x08
#define CNN_IER       0x0C
#define CNN_ISR       0x10

/* ---- frame geometry (ecg_params_pkg) ---- */
#define INPUT_SAMPLES   187
#define OUTPUT_SAMPLES  5
/* MM2S is 32 bits wide and the subset converter takes tdata[15:0], so each
 * signed Q8.8 sample occupies the low half of one 32-bit DDR word. */
#define MM2S_BYTES      (INPUT_SAMPLES * 4)
#define S2MM_BYTES      (OUTPUT_SAMPLES * 2)

/* Input at offset 0, output one page up: the datamover fetches whole 64-byte
 * bursts, so a 748-byte read is issued as 768 bytes. Keeping the output a page
 * away means that over-read can never touch it. */
#define IN_OFF   0x0000
#define OUT_OFF  0x1000

#define PHYS_ATTR "/sys/module/pl_dmabuf/parameters/phys_addr"

static volatile uint8_t *dma_regs, *cnn_regs;

static inline void wr32(volatile uint8_t *base, uint32_t off, uint32_t v)
{
	*(volatile uint32_t *)(base + off) = v;
}
static inline uint32_t rd32(volatile uint8_t *base, uint32_t off)
{
	return *(volatile uint32_t *)(base + off);
}

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/* Read a file of one 16-bit hex word per line. Returns count, or -1. */
static int read_hex(const char *path, uint16_t *out, int max)
{
	char line[64];
	int n = 0;
	FILE *f = fopen(path, "r");

	if (!f) {
		fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
		return -1;
	}
	while (n < max && fgets(line, sizeof line, f)) {
		if (line[0] == 0x0A || line[0] == 0x0D || line[0] == 0x00)
			continue;
		out[n++] = (uint16_t)strtoul(line, NULL, 16);
	}
	fclose(f);
	return n;
}

/* Q8.8 fixed point -> double */
static double q8_8(uint16_t raw) { return (double)(int16_t)raw / 256.0; }

static int wait_idle(uint32_t sr_off, const char *what, double timeout_ms)
{
	double start = now_ms();
	uint32_t sr;

	for (;;) {
		sr = rd32(dma_regs, sr_off);
		if (sr & DMASR_ERR_MSK) {
			fprintf(stderr, "%s error: DMASR=0x%08x\n", what, sr);
			return -1;
		}
		if (sr & DMASR_IDLE)
			return 0;
		if (now_ms() - start > timeout_ms) {
			fprintf(stderr, "%s timed out: DMASR=0x%08x\n", what, sr);
			return -1;
		}
	}
}

/* One complete transfer, assuming the frame is already staged in the buffer.
 * Factored out so the benchmark measures exactly the same work as a single
 * run: channel reset, the programming sequence, and the wait for completion.
 * Everything outside this -- mapping, parsing, staging -- is setup a real
 * application would do once, so it is deliberately excluded from the timing. */
static int run_once(unsigned long phys)
{
	int i;

	wr32(dma_regs, MM2S_DMACR, DMACR_RESET);
	wr32(dma_regs, S2MM_DMACR, DMACR_RESET);
	for (i = 0; i < 1000 &&
	     ((rd32(dma_regs, MM2S_DMACR) | rd32(dma_regs, S2MM_DMACR)) & DMACR_RESET); i++)
		;

	/* 1. arm receive first */
	wr32(dma_regs, S2MM_DA,     (uint32_t)(phys + OUT_OFF));
	wr32(dma_regs, S2MM_DMACR,  DMACR_RUN | DMACR_IOC_IRQ);
	wr32(dma_regs, S2MM_LENGTH, S2MM_BYTES);

	/* 2. clear stale status and start the accelerator */
	wr32(cnn_regs, CNN_GIE, 1);
	wr32(cnn_regs, CNN_IER, 1);
	wr32(cnn_regs, CNN_ISR, 1);
	wr32(cnn_regs, CNN_CTRL, 1);

	/* 3. LENGTH last -- this launches the input transfer */
	wr32(dma_regs, MM2S_SA,     (uint32_t)(phys + IN_OFF));
	wr32(dma_regs, MM2S_DMACR,  DMACR_RUN | DMACR_IOC_IRQ);
	wr32(dma_regs, MM2S_LENGTH, MM2S_BYTES);

	if (wait_idle(MM2S_DMASR, "MM2S", 1000.0)) return -1;
	if (wait_idle(S2MM_DMASR, "S2MM", 1000.0)) return -1;

	__asm__ __volatile__("dsb sy" ::: "memory");

	if (!(rd32(cnn_regs, CNN_STATUS) & 1u)) {
		fprintf(stderr, "CNN done bit never set: STATUS=0x%08x\n",
			rd32(cnn_regs, CNN_STATUS));
		return -1;
	}
	wr32(cnn_regs, CNN_CTRL, 2);   /* clear done/IRQ sticky for the next frame */
	wr32(cnn_regs, CNN_ISR,  1);
	return 0;
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	uint16_t input[INPUT_SAMPLES], golden[OUTPUT_SAMPLES];
	int have_golden = 0, expect_label = -1;
	int mem_fd, buf_fd, n, i, rc = 0;
	int bench_iters = 0, warmup = 5;
	unsigned long phys;
	uint8_t *buf;
	uint32_t *in_words;
	uint16_t *out_words;
	FILE *pf;
	double t0, t1;

	/* --bench N <input.hex> */
	if (argc >= 4 && strcmp(argv[1], "--bench") == 0) {
		bench_iters = atoi(argv[2]);
		argv += 2;
		argc -= 2;
		if (bench_iters < 1) {
			fprintf(stderr, "--bench needs a positive iteration count\n");
			return 2;
		}
	}

	if (argc < 2) {
		fprintf(stderr,
			"usage: %s <input.hex> [golden_logits.hex] [expected_label]\n"
			"       %s --bench <N> <input.hex>\n",
			argv[0], argv[0]);
		return 2;
	}

	n = read_hex(argv[1], input, INPUT_SAMPLES);
	if (n != INPUT_SAMPLES) {
		fprintf(stderr, "expected %d input samples, got %d\n", INPUT_SAMPLES, n);
		return 2;
	}
	if (argc >= 3) {
		if (read_hex(argv[2], golden, OUTPUT_SAMPLES) != OUTPUT_SAMPLES) {
			fprintf(stderr, "bad golden logits file\n");
			return 2;
		}
		have_golden = 1;
	}
	if (argc >= 4)
		expect_label = atoi(argv[3]);

	/* ---- physical address of the coherent buffer ---- */
	pf = fopen(PHYS_ATTR, "r");
	if (!pf) {
		fprintf(stderr, "cannot read %s: %s\nis pl_dmabuf loaded?\n",
			PHYS_ATTR, strerror(errno));
		return 1;
	}
	if (fscanf(pf, "%lu", &phys) != 1) { fclose(pf); return 1; }
	fclose(pf);

	buf_fd = open("/dev/pl_dmabuf", O_RDWR);
	if (buf_fd < 0) { perror("open /dev/pl_dmabuf"); return 1; }
	buf = mmap(NULL, 0x2000, PROT_READ | PROT_WRITE, MAP_SHARED, buf_fd, 0);
	if (buf == MAP_FAILED) { perror("mmap buffer"); return 1; }

	mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem_fd < 0) { perror("open /dev/mem (run as root)"); return 1; }
	dma_regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, DMA_BASE);
	cnn_regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, CNN_BASE);
	if (dma_regs == MAP_FAILED || cnn_regs == MAP_FAILED) {
		perror("mmap registers"); return 1;
	}

	printf("buffer phys 0x%08lx  input@+0x%04x (%d B)  output@+0x%04x (%d B)\n",
	       phys, IN_OFF, MM2S_BYTES, OUT_OFF, S2MM_BYTES);

	/* ---- prove the AXI-Lite path before trusting anything else ---- */
	wr32(cnn_regs, CNN_GIE, 1);
	if (rd32(cnn_regs, CNN_GIE) != 1) {
		fprintf(stderr, "CNN GIE readback failed -- is the PL loaded?\n");
		return 1;
	}
	wr32(cnn_regs, CNN_GIE, 0);

	/* ---- stage the frame ---- */
	in_words  = (uint32_t *)(buf + IN_OFF);
	out_words = (uint16_t *)(buf + OUT_OFF);
	memset(buf, 0, 0x2000);                 /* also defines the burst padding */
	for (i = 0; i < INPUT_SAMPLES; i++)
		in_words[i] = input[i];         /* zero-extended into the low half */

	/* dma_alloc_coherent maps as Normal non-cacheable, which on arm64 is
	 * WEAKLY ordered -- it is uncached, not strongly ordered. The register
	 * writes below go to Device memory through a different mapping, so
	 * without an explicit barrier the CPU may still be draining these frame
	 * writes when the DMA has already been told to start reading them. The
	 * result is a deterministic-looking but partly stale input frame.
	 * dsb sy retires the buffer writes before any register access. */
	__asm__ __volatile__("dsb sy" ::: "memory");

	/* Read the frame back through the same mapping and verify it, so a
	 * staging fault can never be mistaken for an accelerator fault. */
	for (i = 0; i < INPUT_SAMPLES; i++) {
		if (in_words[i] != input[i]) {
			fprintf(stderr,
				"input staging verify failed at word %d: wrote 0x%04X, read 0x%08X\n",
				i, input[i], in_words[i]);
			return 1;
		}
	}

	/* ---- benchmark mode: many transfers, report the distribution ---- */
	if (bench_iters) {
		double *ms = malloc(sizeof(double) * (size_t)bench_iters);
		double sum = 0.0;

		if (!ms) { perror("malloc"); return 1; }

		for (i = 0; i < warmup; i++)
			if (run_once(phys)) return 1;

		for (i = 0; i < bench_iters; i++) {
			t0 = now_ms();
			if (run_once(phys)) { free(ms); return 1; }
			ms[i] = now_ms() - t0;
			sum += ms[i];
		}
		qsort(ms, (size_t)bench_iters, sizeof(double), cmp_double);

		printf("PL accelerator (AXI DMA round trip), %d iterations after %d warmup\n",
		       bench_iters, warmup);
		printf("  min    : %8.3f ms\n", ms[0]);
		printf("  median : %8.3f ms\n", ms[bench_iters / 2]);
		printf("  mean   : %8.3f ms\n", sum / bench_iters);
		printf("  p99    : %8.3f ms\n", ms[(int)(0.99 * (bench_iters - 1))]);
		printf("  max    : %8.3f ms\n", ms[bench_iters - 1]);
		printf("  throughput: %.1f inferences/s\n", 1000.0 * bench_iters / sum);
		free(ms);
		munmap(buf, 0x2000);
		close(buf_fd); close(mem_fd);
		return 0;
	}

	t0 = now_ms();
	rc = run_once(phys) ? 1 : 0;
	t1 = now_ms();

	if (rc) {
		fprintf(stderr, "CNN STATUS=0x%08x\n", rd32(cnn_regs, CNN_STATUS));
		return 1;
	}

	/* ---- results ---- */
	printf("inference round trip: %.3f ms\n", t1 - t0);
	printf("\n idx      raw     Q8.8");
	if (have_golden) printf("   golden    delta");
	printf("\n");
	for (i = 0; i < OUTPUT_SAMPLES; i++) {
		printf("  %2d   0x%04X  %+8.4f", i, out_words[i], q8_8(out_words[i]));
		if (have_golden) {
			printf("   0x%04X  %+8.4f", golden[i],
			       q8_8(out_words[i]) - q8_8(golden[i]));
			if (out_words[i] != golden[i]) rc = 1;
		}
		printf("\n");
	}

	{
		int arg = 0;
		for (i = 1; i < OUTPUT_SAMPLES; i++)
			if ((int16_t)out_words[i] > (int16_t)out_words[arg]) arg = i;
		printf("\npredicted class: %d\n", arg);
		if (expect_label >= 0) {
			printf("expected  class: %d  -> %s\n", expect_label,
			       arg == expect_label ? "MATCH" : "MISMATCH");
			if (arg != expect_label) rc = 1;
		}
	}

	if (have_golden)
		printf("logits vs golden: %s\n", rc ? "MISMATCH" : "BIT-EXACT");

	munmap(buf, 0x2000);
	close(buf_fd); close(mem_fd);
	return rc;
}
