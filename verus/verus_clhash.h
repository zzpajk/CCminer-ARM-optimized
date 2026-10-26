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

#include "sse2neon.h"
uint64_t verusclhash_port2_1(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex);
uint64_t verusclhash_port2_2(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex, __m128i *g_prand, __m128i *g_prandex);

#ifdef VERUS_X2
/* N independent nonces in lockstep (N = 2, 3 or 4); each lane needs its own copy of the key */
template<int N>
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
