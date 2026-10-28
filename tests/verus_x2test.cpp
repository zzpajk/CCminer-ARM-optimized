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
	const int N = VERUS_LANES;
	long iters = argc > 1 ? atol(argv[1]) : 20000, bad = 0;
	alignas(64) __m128i key0[560], keyS[560], keyL[4][560];
	alignas(64) __m128i gpL[4][32], gpxL[4][32], gpS[32], gpxS[32];
	uint16_t frL[4][32], freL[4][32], frS[32], freS[32];
	for (long it = 0; it < iters; it++) {
		if (it % 100 == 0) { fill(key0, sizeof(key0)); }
		alignas(16) unsigned char half[64], bS[64], bL[4][64];
		fill(half, 64);
		unsigned char nonce[4][15], hS[4][32], hL[4][32];
		memset(hS, 0, sizeof(hS)); memset(hL, 0, sizeof(hL));
		memcpy(keyS, key0, sizeof(key0));
		for (int l = 0; l < N; l++) { fill(nonce[l], 15); memcpy(keyL[l], key0, sizeof(key0)); memcpy(bL[l], half, 64); }

		for (int l = 0; l < N; l++) {
			memcpy(bS, half, 64);
			single(hS[l], bS, nonce[l], keyS, frS, freS, gpS, gpxS);
		}
		struct verus_lane L[4];
		unsigned char *hp[4]; const unsigned char *np[4];
		for (int l = 0; l < N; l++) {
			L[l] = (struct verus_lane){ keyL[l], frL[l], freL[l], gpL[l], gpxL[l], bL[l], key0 };   /* key0 = pristine copy (SEL bit 128) */
			hp[l] = hL[l]; np[l] = nonce[l];
		}
		Verus2hash_xN<VERUS_LANES>(hp, L, np);

		bool ok = !memcmp(keyS, key0, sizeof(key0));
		for (int l = 0; l < N; l++)
			ok = ok && !memcmp(hS[l], hL[l], 32) && !memcmp(keyL[l], key0, sizeof(key0));
		if (!ok) { if (bad < 5) printf("mismatch at iteration %ld\n", it); bad++; }
	}
	printf("x2test (%d lanes): %ld iterations, %ld mismatches -> %s\n", N, iters, bad, bad ? "FAIL" : "PASS");
	return bad != 0;
}
