/* Checks that sorted hashing (verus_sort.h: 32 hashes in flight, rounds grouped by case) gives exactly what
 * single-nonce runs give: same 32-byte hashes, key restored after every hash. Build with -DVERUS_X2. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "verus_sort.h"

static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static void fill(void *p, size_t n) { unsigned char *c = (unsigned char *)p; for (size_t i = 0; i < n; i++) c[i] = (unsigned char)rnd(); }

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

enum { NL = VERUS_SORT_LANES, M = 1000 };
static struct verus_sort S;
static struct verus_slane lane[NL] __attribute__((aligned(64)));
static __m128i key0[560] __attribute__((aligned(64))), keyS[560] __attribute__((aligned(64))), keyL[NL][560] __attribute__((aligned(64)));
static unsigned char bL[NL][64] __attribute__((aligned(16))), nonce0[15];
static unsigned char hL[M][32];
static uint32_t next, got; static long dirty;

static void put_nonce(unsigned char *n, uint32_t v) { memcpy(n, nonce0, 15); memcpy(n + 11, &v, 4); }
static int cb(void *)
{
	for (uint32_t k = 0; k < S.cnt[8]; k++) {
		const int id = S.bk[8][k]; struct verus_slane *s = lane + id;
		unsigned char h[32]; memset(h, 0, 32);
		verus_sort_finish(s, h, key0);
		if (memcmp(s->key, key0, sizeof(key0))) dirty++;
		if (s->nonce < M) { memcpy(hL[s->nonce], h, 32); got++; }
		unsigned char n[15]; s->nonce = next++; put_nonce(n, s->nonce);
		verus_sort_start(&S, id, n);
	}
	S.cnt[8] = 0;
	return got >= M;
}

int main(int argc, char **argv)
{
	long iters = argc > 1 ? atol(argv[1]) : 20000, bad = 0, done = 0;
	const int pf = argc > 2 ? atoi(argv[2]) : 1;
	static __m128i gpS[32], gpxS[32]; static uint16_t frS[32], freS[32];
	while (done < iters) {
		alignas(16) unsigned char half[64], bS[64];
		fill(key0, sizeof(key0)); fill(half, 64); fill(nonce0, 15);
		memcpy(keyS, key0, sizeof(key0));
		memset(&S, 0, sizeof(S)); S.lane = lane; next = 0; got = 0; dirty = 0;
		for (int l = 0; l < NL; l++) {
			memcpy(keyL[l], key0, sizeof(key0)); memcpy(bL[l], half, 64);
			lane[l].key = keyL[l]; lane[l].buf = bL[l];
			unsigned char n[15]; lane[l].nonce = next++; put_nonce(n, lane[l].nonce);
			verus_sort_start(&S, l, n);
		}
		verus_sort_run(&S, cb, NULL, pf);
		long b = dirty + (got != M);
		for (uint32_t v = 0; v < M; v++) {
			unsigned char n[15], hS[32]; memset(hS, 0, 32); put_nonce(n, v);
			memcpy(bS, half, 64);
			single(hS, bS, n, keyS, frS, freS, gpS, gpxS);
			if (memcmp(hS, hL[v], 32)) b++;
		}
		if (memcmp(keyS, key0, sizeof(key0))) b++;
		if (b && bad < 5) printf("mismatches in block at %ld: %ld\n", done, b);
		bad += b; done += M;
	}
	printf("sorttest (%d in flight, prefetch %d): %ld hashes, %ld mismatches -> %s\n", NL, pf, done, bad, bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
