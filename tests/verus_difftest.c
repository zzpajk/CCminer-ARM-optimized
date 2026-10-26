/*
 * verus_difftest - differential test between the baseline Haraka512 keyed
 * permutation and a named variant, on the target CPU.
 *
 * Build (done by verus-ref-bench.sh):
 *   clang -O2 -march=armv8-a+crypto -I. -Iverus -Dharaka512_keyed=haraka512_keyed_base -c verus/haraka.c -o hb.o
 *   clang -O2 -march=armv8-a+crypto -I. -Iverus -DVERUS_ZIPMIX -Dharaka512_keyed=haraka512_keyed_var -c verus/haraka.c -o hv.o
 *   clang -O2 -march=armv8-a+crypto -I. -Iverus tests/verus_difftest.c hb.o hv.o -o difftest
 *
 * Runs N random (input, round-constant-table) pairs through both functions
 * and compares all 32 output bytes. Exit status 0 = identical, 1 = mismatch.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "sse2neon.h"

extern void haraka512_keyed_base(unsigned char *out, const unsigned char *in, const __m128i *rc);
extern void haraka512_keyed_var(unsigned char *out, const unsigned char *in, const __m128i *rc);

static uint64_t rng_state = 0x9E3779B97F4A7C15ULL;
static uint64_t rng(void) {            /* xorshift64* */
    rng_state ^= rng_state >> 12; rng_state ^= rng_state << 25; rng_state ^= rng_state >> 27;
    return rng_state * 0x2545F4914F6CDD1DULL;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 2000000;
    if (argc > 2) rng_state ^= strtoull(argv[2], 0, 0);
    unsigned char in[64] __attribute__((aligned(16)));
    __m128i rc[64] __attribute__((aligned(16)));
    unsigned char ob[32], ov[32];
    long bad = 0;
    for (long it = 0; it < n; it++) {
        for (int i = 0; i < 64; i += 8) { uint64_t r = rng(); memcpy(in + i, &r, 8); }
        for (int i = 0; i < 64; i++) { uint64_t r[2] = { rng(), rng() }; memcpy(&rc[i], r, 16); }
        memset(ob, 0, 32); memset(ov, 0, 32);
        haraka512_keyed_base(ob, in, rc);
        haraka512_keyed_var(ov, in, rc);
        if (memcmp(ob, ov, 32) != 0) {
            if (++bad <= 3) {
                printf("MISMATCH at iteration %ld\n  base:", it);
                for (int i = 0; i < 32; i++) printf("%02x", ob[i]);
                printf("\n  var: ");
                for (int i = 0; i < 32; i++) printf("%02x", ov[i]);
                printf("\n");
            }
        }
    }
    printf("difftest: %ld iterations, %ld mismatches -> %s\n", n, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
