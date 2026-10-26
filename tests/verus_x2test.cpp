/* Checks that the two-nonce interleaved path (variant x2) produces exactly what two single-nonce runs
 * produce: same 32-byte hashes, same restored key. Build with -DVERUS_X2 (see the CI workflow). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "verus_x2.h"

static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static void fill(void *p, size_t n) { unsigned char *c = (unsigned char *)p; for (size_t i = 0; i < n; i++) c[i] = (unsigned char)rnd(); }

/* the single-nonce sequence exactly as Verus2hash() + FixKey() in verusscan.cpp */
static void single(unsigned char *hash, unsigned char *buf, const unsigned char *nonce, __m128i *key,
		uint16_t *fr, uint16_t *fre, __m128i *gp, __m128i *gpx)
{
	memcpy(buf + 47, buf, 16); memcpy(buf + 63, buf, 1);
	memcpy(buf + 32, nonce, 15);
	uint64_t im = verusclhash_port2_2(key, buf, 511, fr, fre, gp, gpx);
	memcpy(buf + 47, &im, 8); memcpy(buf + 55, &im, 8); memcpy(buf + 63, &im, 1);
	haraka512_keyed(hash, buf, key + (im & 511));
	for (int i = 31; i > -1; i--) { key[fr[i]] = gp[i]; key[fre[i]] = gpx[i]; }
}

int main(int argc, char **argv)
{
	long iters = argc > 1 ? atol(argv[1]) : 20000, bad = 0;
	alignas(64) __m128i key0[560], keyS[560], keyA[560], keyB[560];
	alignas(64) __m128i gp[3][32], gpx[3][32];
	uint16_t fr[3][32], fre[3][32];
	for (long it = 0; it < iters; it++) {
		if (it % 100 == 0) { fill(key0, sizeof(key0)); }
		alignas(16) unsigned char half[64], bS[64], bA[64], bB[64];
		fill(half, 64);
		unsigned char nA[15], nB[15], hS1[32] = {0}, hS2[32] = {0}, hA[32] = {0}, hB[32] = {0};
		fill(nA, 15); fill(nB, 15);
		memcpy(keyS, key0, sizeof(key0)); memcpy(keyA, key0, sizeof(key0)); memcpy(keyB, key0, sizeof(key0));
		memcpy(bS, half, 64); memcpy(bA, half, 64); memcpy(bB, half, 64);

		single(hS1, bS, nA, keyS, fr[2], fre[2], gp[2], gpx[2]);
		memcpy(bS, half, 64);
		single(hS2, bS, nB, keyS, fr[2], fre[2], gp[2], gpx[2]);

		struct verus_lane LA = { keyA, fr[0], fre[0], gp[0], gpx[0], bA };
		struct verus_lane LB = { keyB, fr[1], fre[1], gp[1], gpx[1], bB };
		Verus2hash_x2(hA, hB, &LA, &LB, nA, nB);

		if (memcmp(hS1, hA, 32) || memcmp(hS2, hB, 32) || memcmp(keyA, key0, sizeof(key0)) ||
		    memcmp(keyB, key0, sizeof(key0)) || memcmp(keyS, key0, sizeof(key0))) {
			if (bad < 5) printf("mismatch at iteration %ld\n", it);
			bad++;
		}
	}
	printf("x2test: %ld iterations, %ld mismatches -> %s\n", iters, bad, bad ? "FAIL" : "PASS");
	return bad != 0;
}
