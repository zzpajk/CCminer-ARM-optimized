/* Checks variant "pristine": hashing without the per-round key journal and restoring the key from a
 * pristine copy gives exactly the same hashes and the same restored key as the original journal +
 * FixKey sequence. The key is NOT reset between nonces (only every 1000 iterations), so a restore that
 * missed a position would corrupt every later hash and be caught. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "verus_clhash.h"
extern "C" {
#include "haraka.h"
}

static uint64_t rs = 0x2545F4914F6CDD1DULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static void fill(void *p, size_t n) { unsigned char *c = (unsigned char *)p; for (size_t i = 0; i < n; i++) c[i] = (unsigned char)rnd(); }

int main(int argc, char **argv)
{
	long iters = argc > 1 ? atol(argv[1]) : 100000, bad = 0;
	alignas(64) __m128i key0[560], keyJ[560], keyP[560], gp[32], gpx[32];
	uint16_t frJ[32], freJ[32], frP[32], freP[32];
	alignas(16) unsigned char half[64], bJ[64], bP[64], hJ[32], hP[32];
	for (long it = 0; it < iters; it++) {
		if (it % 1000 == 0) { fill(key0, sizeof(key0)); memcpy(keyJ, key0, sizeof(key0)); memcpy(keyP, key0, sizeof(key0)); fill(half, 64); }
		unsigned char nonce[15];
		fill(nonce, 15);
		memcpy(bJ, half, 64); memcpy(bP, half, 64);
		memset(hJ, 0, 32); memset(hP, 0, 32);

		/* original: Verus2hash() + FixKey() */
		memcpy(bJ + 47, bJ, 16); memcpy(bJ + 63, bJ, 1); memcpy(bJ + 32, nonce, 15);
		uint64_t imJ = verusclhash_port2_2(keyJ, bJ, 511, frJ, freJ, gp, gpx);
		memcpy(bJ + 47, &imJ, 8); memcpy(bJ + 55, &imJ, 8); memcpy(bJ + 63, &imJ, 1);
		haraka512_keyed(hJ, bJ, keyJ + (imJ & 511));
		for (int i = 31; i > -1; i--) { keyJ[frJ[i]] = gp[i]; keyJ[freJ[i]] = gpx[i]; }

		/* pristine: Verus2hash_pristine() in verusscan.cpp */
		memcpy(bP + 47, bP, 16); memcpy(bP + 63, bP, 1); memcpy(bP + 32, nonce, 15);
#ifdef PRISTINE_PRE
		uint64_t imP = verusclhash_port2_2_nojournal_pre(keyP, bP, 511, frP, freP);   /* + preload */
#else
		uint64_t imP = verusclhash_port2_2_nojournal(keyP, bP, 511, frP, freP);
#endif
		memcpy(bP + 47, &imP, 8); memcpy(bP + 55, &imP, 8); memcpy(bP + 63, &imP, 1);
		haraka512_keyed(hP, bP, keyP + (imP & 511));
		verus_fixkey_pristine(frP, freP, keyP, key0);

		bool ok = imJ == imP && !memcmp(hJ, hP, 32) && !memcmp(keyJ, key0, sizeof(key0)) && !memcmp(keyP, key0, sizeof(key0));
		if (!ok) { if (bad < 5) printf("mismatch at iteration %ld\n", it); bad++; }
	}
#ifdef PRISTINE_PRE
	printf("pristinetest preload: %ld iterations, %ld mismatches -> %s\n", iters, bad, bad ? "FAIL" : "PASS");
	return bad != 0;
#endif
	printf("pristinetest: %ld iterations, %ld mismatches -> %s\n", iters, bad, bad ? "FAIL" : "PASS");
	return bad != 0;
}
