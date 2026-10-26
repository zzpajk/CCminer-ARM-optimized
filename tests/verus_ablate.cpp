/* Timing harness for the ablation builds: single-nonce Verus pipeline (same sequence as Verus2hash() +
 * FixKey()) on a fixed key, nonce counting up, for a fixed number of seconds. Prints hashes per second.
 * With -DVERUS_ABL_NOFIX the key restore is skipped (also wrong on purpose, for timing only). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "verus_clhash.h"
extern "C" {
#include "haraka.h"
}
static uint64_t rs = 0x1234567899ULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
int main(int argc, char **argv)
{
	double secs = argc > 1 ? atof(argv[1]) : 3.0;
	alignas(64) __m128i key[560], gp[32], gpx[32];
	uint16_t fr[32], fre[32];
	alignas(16) unsigned char buf[64], hash[32];
	for (size_t i = 0; i < sizeof(key); i++) ((unsigned char *)key)[i] = (unsigned char)rnd();
	for (int i = 0; i < 64; i++) buf[i] = (unsigned char)rnd();
	unsigned char nonce[15] = {0};
	uint64_t n = 0, sink = 0;
	double t0 = now(), t1 = t0;
	while (t1 - t0 < secs) {
		for (int k = 0; k < 256; k++, n++) {
			memcpy(nonce + 11, &n, 4);
			memcpy(buf + 47, buf, 16); memcpy(buf + 63, buf, 1);
			memcpy(buf + 32, nonce, 15);
			uint64_t im = verusclhash_port2_2(key, buf, 511, fr, fre, gp, gpx);
			memcpy(buf + 47, &im, 8); memcpy(buf + 55, &im, 8); memcpy(buf + 63, &im, 1);
#ifndef VERUS_ABL_NOHARAKA
			haraka512_keyed(hash, buf, key + (im & 511));
#else
			hash[28] = (unsigned char)im;   /* timing experiment only */
#endif
			sink += hash[28];
#ifndef VERUS_ABL_NOFIX
			for (int i = 31; i > -1; i--) { key[fr[i]] = gp[i]; key[fre[i]] = gpx[i]; }
#endif
		}
		t1 = now();
	}
	printf("%.0f\n", n / (t1 - t0));
	if (sink == 12345678901ULL) printf("x\n");
	return 0;
}
