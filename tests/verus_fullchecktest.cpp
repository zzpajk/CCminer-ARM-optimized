/* Checks the full-hash share check in verusscan.cpp (verus_full_check): the fast Haraka512 stores only the
 * top 32-bit word of the hash, the portable reference stores all 256 bits. For the same key state, buffer
 * and nonce, the portable top word must equal the fast one, so the full hash it computes is the hash the
 * fast loop found. Also counts how many "top word passes" candidates the full hash rejects for a target
 * like a pool's (top word 1, then 0x58e4ffff...): about (1 - 0.347) / 2 = 33% of candidates. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "verus_clhash.h"
extern "C" {
#include "haraka_portable.h"
#include "haraka.h"
}

static uint64_t rs = 0x853C49E6748FEA9BULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static void fill(void *p, size_t n) { unsigned char *c = (unsigned char *)p; for (size_t i = 0; i < n; i++) c[i] = (unsigned char)rnd(); }

/* one hash of the miner's single-nonce sequence; key is restored afterwards (journal + FixKey) */
static void hash_once(uint32_t *out, int full, const unsigned char *half, const unsigned char *nonce, __m128i *key)
{
	alignas(64) __m128i gp[32], gpx[32];
	uint16_t fr[32], fre[32];
	alignas(16) unsigned char buf[64];
	memcpy(buf, half, 64);
	memcpy(buf + 47, buf, 16); memcpy(buf + 63, buf, 1);
	memcpy(buf + 32, nonce, 15);
	uint64_t im = verusclhash_port2_2(key, buf, 511, fr, fre, gp, gpx);
	memcpy(buf + 47, &im, 8); memcpy(buf + 55, &im, 8); memcpy(buf + 63, &im, 1);
	if (full) haraka512_port_keyed((unsigned char *)out, buf, key + (im & 511));
	else haraka512_keyed((unsigned char *)out, buf, key + (im & 511));
	for (int i = 31; i > -1; i--) { key[fr[i]] = gp[i]; key[fre[i]] = gpx[i]; }
}

int main(int argc, char **argv)
{
	long iters = argc > 1 ? atol(argv[1]) : 100000, bad = 0, cand = 0, low = 0;
	alignas(64) __m128i key[560], key0[560];
	alignas(16) unsigned char half[64];
	uint32_t target[8];
	memset(target, 0xff, sizeof(target));
	target[7] = 0x00000001; target[6] = 0x58e4ffff;
	load_constants_port();
	for (long it = 0; it < iters; it++) {
		if (it % 1000 == 0) { fill(key0, sizeof(key0)); memcpy(key, key0, sizeof(key0)); fill(half, 64); }
		unsigned char nonce[15];
		fill(nonce, 15);
		uint32_t fast[8], full[8];
		memset(fast, 0, sizeof(fast));
		hash_once(fast, 0, half, nonce, key);
		hash_once(full, 1, half, nonce, key);
		if (full[7] != fast[7] || memcmp(key, key0, sizeof(key0))) {
			if (bad++ < 5) printf("mismatch at %ld: fast top %08x full top %08x\n", it, fast[7], full[7]);
		}
		/* candidate statistics on the low bits: pretend the top word passed (0 or 1 at random) */
		full[7] = (uint32_t)(rnd() & 1);
		cand++;
		int ok = 1;
		for (int i = 7; i >= 0; i--) { if (full[i] < target[i]) { ok = 1; break; } if (full[i] > target[i]) { ok = 0; break; } }
		if (!ok) low++;
	}
	printf("fullchecktest: %ld hashes, %ld mismatches, %.1f%% of top-word candidates above the target -> %s\n",
		iters, bad, 100.0 * low / (cand ? cand : 1), bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
