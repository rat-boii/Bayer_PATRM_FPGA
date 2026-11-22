/* Laptop wrapper for the software baseline (step 4.4), used by model/test_patrm_sw.py.
 *
 *   patrm_sw_host <src.raw> <W> <H> <b11> <b12> <b13> <b21> <b22> <b23> <out.raw> [repeats]
 *
 * Reads a raw GRAY8 image of W x H bytes, warps it with patrm_sw_gray and writes the output. With repeats > 0 it also
 * runs the warp that many times and prints "TIME_US <average microseconds per frame>" (laptop timing, information only).
 * Exit code 0 on success.
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "patrm_sw.h"

static int read_exact(const char *path, uint8_t *buf, size_t n)
{
    FILE *f = fopen(path, "rb");
    size_t got;
    int extra;

    if (f == NULL) {
        return -1;
    }
    got = fread(buf, 1, n, f);
    extra = fgetc(f);
    fclose(f);
    return ((got == n) && (extra == EOF)) ? 0 : -1;
}

int main(int argc, char **argv)
{
    uint32_t W, H;
    int32_t b[6];
    size_t n;
    uint8_t *src, *dst;
    FILE *f;
    int i, rc, repeats = 0;

    if ((argc != 11) && (argc != 12)) {
        fprintf(stderr, "usage: %s <src.raw> <W> <H> <b11> <b12> <b13> <b21> <b22> <b23> <out.raw> [repeats]\n", argv[0]);
        return 2;
    }
    W = (uint32_t)strtoul(argv[2], NULL, 10);
    H = (uint32_t)strtoul(argv[3], NULL, 10);
    for (i = 0; i < 6; i++) {
        b[i] = (int32_t)strtol(argv[4 + i], NULL, 10);
    }
    if (argc == 12) {
        repeats = atoi(argv[11]);
    }
    n = (size_t)W * H;
    src = malloc(n ? n : 1U);
    dst = malloc(n ? n : 1U);
    if ((src == NULL) || (dst == NULL)) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }
    if (read_exact(argv[1], src, n) != 0) {
        fprintf(stderr, "%s: cannot read exactly %u x %u bytes\n", argv[1], (unsigned)W, (unsigned)H);
        return 1;
    }
    rc = patrm_sw_gray(src, dst, W, H, b);
    if (rc != PATRM_SW_OK) {
        fprintf(stderr, "patrm_sw_gray returned %d\n", rc);
        return 1;
    }
    f = fopen(argv[10], "wb");
    if ((f == NULL) || (fwrite(dst, 1, n, f) != n)) {
        fprintf(stderr, "%s: cannot write\n", argv[10]);
        return 1;
    }
    fclose(f);
    if (repeats > 0) {
        clock_t t0 = clock();
        for (i = 0; i < repeats; i++) {
            (void)patrm_sw_gray(src, dst, W, H, b);
        }
        printf("TIME_US %.1f\n", 1e6 * (double)(clock() - t0) / CLOCKS_PER_SEC / repeats);
    }
    free(src);
    free(dst);
    return 0;
}
