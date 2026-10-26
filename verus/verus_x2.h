/* Multi-nonce interleaved Verus2hash (variants x2, x3, x4, auto). Only compiled with -DVERUS_X2.
 * Hashes N nonces in lockstep (N = VERUS_LANES, default 2). Each lane has its own copy of the 8,832-byte key
 * because a nonce mutates the key while it is hashed (and restores it afterwards), so lanes must not share it.
 * The per-lane steps are the same code as the single-nonce path; only the order of execution differs, which
 * lets an out-of-order core overlap the dependency chains. Results must be bit-identical to running
 * Verus2hash N times (tests/verus_x2test.cpp checks that). */
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

#ifndef VERUS_LANES
#define VERUS_LANES 2
#endif

struct verus_lane {
	__m128i *key;                   /* private copy of the generated key (>= 552 x 16 bytes) */
	uint16_t *fixrand, *fixrandex;  /* 32 entries each */
	__m128i *gp, *gpx;              /* 32 entries each */
	unsigned char *buf;             /* private 64-byte VerusHashHalf copy */
};

static inline void verus_fixkey_lane(const struct verus_lane *l)
{
	for (int i = 31; i >= 0; i--) {
		l->key[l->fixrand[i]] = l->gp[i];
		l->key[l->fixrandex[i]] = l->gpx[i];
	}
}

/* Same sequence as Verus2hash() for each lane. nonce[l] points to the 15 nonce bytes of lane l;
 * hash[l] receives that lane's 32-byte result. */
template<int N>
static inline void Verus2hash_xN(unsigned char *const *hash, struct verus_lane *L, const unsigned char *const *nonce)
{
	void *rs[N]; const unsigned char *bf[N]; uint16_t *fr[N], *fre[N]; __m128i *gp[N], *gpx[N]; uint64_t im[N];
	for (int l = 0; l < N; l++) {
		unsigned char *b = L[l].buf;
		memcpy(b + 47, b, 16);  memcpy(b + 63, b, 1);
		memcpy(b + 32, nonce[l], 15);
		rs[l] = L[l].key; bf[l] = b; fr[l] = L[l].fixrand; fre[l] = L[l].fixrandex; gp[l] = L[l].gp; gpx[l] = L[l].gpx;
	}
#ifdef VERUS_FUSE
	if (N == 2)
		verusclhash_port2_2_fuse2((__m128i *)rs[0], (__m128i *)rs[1], bf[0], bf[1], 511,
				fr[0], fre[0], gp[0], gpx[0], fr[N - 1], fre[N - 1], gp[N - 1], gpx[N - 1], im);
	else
#endif
	verusclhash_port2_2_xN<N>(rs, bf, 511, fr, fre, gp, gpx, im);
	for (int l = 0; l < N; l++) {
		unsigned char *b = L[l].buf;
		memcpy(b + 47, &im[l], 8); memcpy(b + 55, &im[l], 8); memcpy(b + 63, &im[l], 1);
#ifndef VERUS_ABL_NOHARAKA
		haraka512_keyed(hash[l], b, L[l].key + (im[l] & 511));
#else
		hash[l][28] = (unsigned char)im[l];   /* timing experiment only (tests/verus_ablate.cpp) */
#endif
	}
#ifndef VERUS_ABL_NOFIX
	for (int l = 0; l < N; l++) verus_fixkey_lane(&L[l]);
#endif
}

#endif /* VERUS_X2 */
#endif
