/*
 * leak_harness — drives the printable_binary C FFI in a tight, time-bounded loop
 * and prints its own resident-set size (RSS) periodically, so test/leak_test can
 * watch for monotonically growing memory (a leak) vs. the flat, bounded memory of
 * correct streaming.
 *
 * Exercises every allocating FFI entry point (encode/decode/format/hexlike) plus
 * the non-allocating ones (validate/detect), freeing each result with pb_free.
 * Inputs are deterministic pseudo-random so runs are reproducible.
 *
 *   leak_harness [seconds]    # self-terminates after N seconds (default 8)
 *
 * It is deliberately TIME-BOUNDED (never an infinite loop) so it can never run
 * away if an external sampler forgets to kill it. It reports RSS itself because
 * `ps -o rss` is entitlement-blocked on macOS and /proc is absent there.
 */
#include <stdint.h>
#include <stddef.h>
#include "printable_binary.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach.h>
static long rss_kb(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (long)(info.resident_size / 1024);
}
#else
#include <unistd.h>
static long rss_kb(void) {
    FILE *f = fopen("/proc/self/statm", "r");
    if (!f) return -1;
    long total = 0, resident = 0;
    int n = fscanf(f, "%ld %ld", &total, &resident);
    fclose(f);
    if (n != 2) return -1;
    return resident * (sysconf(_SC_PAGESIZE) / 1024);
}
#endif

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* Deterministic LCG — no libc rand() dependency, reproducible across platforms. */
static uint64_t rng_state = 0x9E3779B97F4A7C15ULL;
static uint32_t next_rng(void) {
    rng_state = rng_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return (uint32_t)(rng_state >> 33);
}

int main(int argc, char **argv) {
    long max_seconds = (argc > 1) ? atol(argv[1]) : 8;
    if (max_seconds <= 0) max_seconds = 8;
    const long start_ms = now_ms();
    const long deadline_ms = start_ms + max_seconds * 1000L;
    long last_sample_ms = start_ms;
    static unsigned char buf[8192];

    printf("RSS %ld\n", rss_kb());
    fflush(stdout);

    for (long i = 0;; i++) {
        if ((i & 0x3FF) == 0) { /* cheap gate; sample on a wall-clock cadence */
            const long t = now_ms();
            if (t >= deadline_ms) break;
            if (t - last_sample_ms >= 100) { /* ~10 samples/sec, loop-speed independent */
                printf("RSS %ld\n", rss_kb());
                fflush(stdout);
                last_sample_ms = t;
            }
        }

        size_t len = (size_t)(next_rng() % (sizeof(buf) + 1));
        for (size_t k = 0; k < len; k++) buf[k] = (unsigned char)next_rng();

        /* encode -> decode + format roundtrips */
        pb_ffi_result_t enc = pb_encode((const char *)buf, len, 0, NULL, 0);
        if (enc.error_code == 0 && enc.data) {
            pb_ffi_result_t dec = pb_decode(enc.data, enc.len, 0);
            if (dec.error_code == 0 && dec.data) pb_free(dec.data, dec.len);
            pb_ffi_result_t fmt = pb_format(enc.data, enc.len, 8, 10, 0);
            if (fmt.error_code == 0 && fmt.data) pb_free(fmt.data, fmt.len);
            pb_free(enc.data, enc.len);
        }

        /* hexlike encode -> decode roundtrip */
        pb_ffi_result_t hx = pb_hexlike_encode((const char *)buf, len, 0);
        if (hx.error_code == 0 && hx.data) {
            pb_ffi_result_t hd = pb_hexlike_decode(hx.data, hx.len, 0);
            if (hd.error_code == 0 && hd.data) pb_free(hd.data, hd.len);
            pb_free(hx.data, hx.len);
        }

        /* non-allocating exports */
        (void)pb_validate((const char *)buf, len, 0);
        (void)pb_detect_double_encode((const char *)buf, len, 0.05f);
    }

    printf("RSS %ld\n", rss_kb());
    fflush(stdout);
    return 0;
}
