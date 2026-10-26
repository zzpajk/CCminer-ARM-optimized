/* Two-nonce interleaved Verus2hash (variant "x2"). Only compiled with -DVERUS_X2.
 * Hashes nonce A and nonce B in lockstep. Each lane has its own copy of the 8,832-byte key because a
 * nonce mutates the key while it is hashed (and restores it afterwards), so the lanes must not share it.
 * The per-lane steps are the same code as the single-nonce path; only the order of execution differs,
 * which lets an out-of-order core overlap the two dependency chains. Results must be bit-identical to
 * running Verus2hash twice (tests/verus_x2test.cpp checks that). */
#ifndef VERUS_X2_H
#define VERUS_X2_H
#ifdef VERUS_X2

#include <string.h>
#include <stdint.h>
#include "verus_clhash.h"
#ifdef __cplusplus
extern "C" {
#endif
#include "haraka.h"
#ifdef __cplusplus
}
#endif

struct verus_lane {
	__m128i *key;                 /* private copy of the generated key (>= 552 x 16 bytes) */
	uint16_t *fixrand, *fixrandex;  /* 32 entries each */
	__m128i *gp, *gpx;            /* 32 entries each */
	unsigned char *buf;           /* private 64-byte VerusHashHalf copy */
};

static inline void verus_fixkey_lane(const struct verus_lane *l)
{
	for (int i = 31; i >= 0; i--) {
		l->key[l->fixrand[i]] = l->gp[i];
		l->key[l->fixrandex[i]] = l->gpx[i];
	}
}

/* Same sequence as Verus2hash() for each lane. nonce points to the 15 nonce bytes of that lane. */
static inline void Verus2hash_x2(unsigned char *hashA, unsigned char *hashB,
		struct verus_lane *A, struct verus_lane *B,
		const unsigned char *nonceA, const unsigned char *nonceB)
{
	unsigned char *bA = A->buf, *bB = B->buf;
	memcpy(bA + 47, bA, 16);  memcpy(bA + 63, bA, 1);
	memcpy(bB + 47, bB, 16);  memcpy(bB + 63, bB, 1);
	memcpy(bA + 32, nonceA, 15);
	memcpy(bB + 32, nonceB, 15);

	uint64_t im[2];
	verusclhash_port2_2_x2(A->key, B->key, bA, bB, 511,
			A->fixrand, A->fixrandex, A->gp, A->gpx,
			B->fixrand, B->fixrandex, B->gp, B->gpx, im);

	memcpy(bA + 47, &im[0], 8); memcpy(bA + 55, &im[0], 8); memcpy(bA + 63, &im[0], 1);
	memcpy(bB + 47, &im[1], 8); memcpy(bB + 55, &im[1], 8); memcpy(bB + 63, &im[1], 1);
	haraka512_keyed(hashA, bA, A->key + (im[0] & 511));
	haraka512_keyed(hashB, bB, B->key + (im[1] & 511));
	verus_fixkey_lane(A);
	verus_fixkey_lane(B);
}

#endif /* VERUS_X2 */
#endif
