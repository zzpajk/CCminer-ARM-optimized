/*
 * This uses veriations of the clhash algorithm for Verus Coin, licensed
 * with the Apache-2.0 open source license.
 * 
 * Copyright (c) 2018 Michael Toutonghi
 * Distributed under the Apache 2.0 software license, available in the original form for clhash
 * here: https://github.com/lemire/clhash/commit/934da700a2a54d8202929a826e2763831bd43cf7#diff-9879d6db96fd29134fc802214163b95a
 * 
 * CLHash is a very fast hashing function that uses the
 * carry-less multiplication and SSE instructions.
 *
 * Original CLHash code (C) 2017, 2018 Daniel Lemire and Owen Kaser
 * Faster 64-bit universal hashing
 * using carry-less multiplications, Journal of Cryptographic Engineering (to appear)
 *
 * Best used on recent x64 processors (Haswell or better).
 *
 **/

#ifndef VERUS_CLHASH_H_GUARD
#define VERUS_CLHASH_H_GUARD
#include "sse2neon.h"
uint64_t verusclhash_port2_1(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex);
uint64_t verusclhash_port2_2(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex, __m128i *g_prand, __m128i *g_prandex);
uint64_t verusclhash_port2_2_nojournal(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex);
/* variant "pristine": undo one hash's key mutations by copying the touched positions back from an
 * unmodified copy of the key. Order does not matter (every touched position gets its original value). */
static inline void verus_fixkey_pristine(const uint16_t * __restrict fixrand, const uint16_t * __restrict fixrandex,
		__m128i * __restrict key, const __m128i * __restrict pristine)
{
	for (int i = 0; i < 32; i++) {
		key[fixrand[i]] = pristine[fixrand[i]];
		key[fixrandex[i]] = pristine[fixrandex[i]];
	}
}

#ifdef VERUS_X2
/* N independent nonces in lockstep (N = 2, 3 or 4); each lane needs its own copy of the key */
/* SEL bit 0: branch-free inner choice in case 0x14, bit 1: same in case 0x18 (variants x2sel, x2sel2),
 * bit 2: case 0x14 entirely branch-free, all 8 steps computed and masked (variant x2sel3, used as SEL 7),
 * bit 3: fused dispatch, one 64-way jump on the pair of cases per round (SEL 8, 9, 11),
 * bit 4: light merge, cases 0/4/8/0x1c as one branch-free body (5 jump targets instead of 8),
 * bit 5: case 0x0c without its 50/50 branch (SEL 16, 32, 48, 19, 35, 51 are instantiated).
 * The default comes from the build flags; x2percore picks it per core at run time. */
#if defined(VERUS_SEL_FORCE)
#  define VERUS_SEL_DEFAULT VERUS_SEL_FORCE   /* tests: any instantiated SEL value */
#elif defined(VERUS_FUSE64)
#  define VERUS_SEL_DEFAULT 11
#elif defined(VERUS_SEL3)
#  define VERUS_SEL_DEFAULT 7
#elif defined(VERUS_SEL14) && defined(VERUS_SEL18)
#  define VERUS_SEL_DEFAULT 3
#elif defined(VERUS_SEL14)
#  define VERUS_SEL_DEFAULT 1
#elif defined(VERUS_SEL18)
#  define VERUS_SEL_DEFAULT 2
#else
#  define VERUS_SEL_DEFAULT 0
#endif
template<int N, int SEL = VERUS_SEL_DEFAULT>
void verusclhash_port2_2_xN(void **random, const unsigned char **buf, uint64_t keyMask,
		uint16_t **fixrand, uint16_t **fixrandex, __m128i **g_prand, __m128i **g_prandex, uint64_t *out);
#ifdef VERUS_FUSE
/* two lanes, one 64-way dispatch per round on the pair of cases (variant x2fuse) */
void verusclhash_port2_2_fuse2(__m128i * __restrict rsA, __m128i * __restrict rsB,
		const unsigned char *bufA, const unsigned char *bufB, uint64_t keyMask,
		uint16_t * __restrict fixrandA, uint16_t * __restrict fixrandexA, __m128i * __restrict g_prandA, __m128i * __restrict g_prandexA,
		uint16_t * __restrict fixrandB, uint16_t * __restrict fixrandexB, __m128i * __restrict g_prandB, __m128i * __restrict g_prandexB,
		uint64_t out[2]);
#endif
#endif
#endif /* VERUS_CLHASH_H_GUARD */
