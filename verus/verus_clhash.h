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
uint64_t verusclhash_port2_2_nojournal_pre(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex);
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

/* SEL bit 18 (262144), "batch": the same restores with four rounds per step, all index loads first, then all
 * eight key loads, then all eight stores. One round at a time is a chain index load -> key load -> store,
 * which an in-order core (Cortex-A53) waits through 32 times per hash. Every store writes the pristine value
 * of its own position, so the order does not matter (also when positions repeat). */
static inline void verus_fixkey_pristine_b4(const uint16_t * __restrict fixrand, const uint16_t * __restrict fixrandex,
		__m128i * __restrict key, const __m128i * __restrict pristine)
{
	typedef uint64_t __attribute__((may_alias)) u64a;
	const u64a *fa = (const u64a *)fixrand, *fb = (const u64a *)fixrandex;
	for (int i = 0; i < 8; i++) {
		const uint64_t a = fa[i], b = fb[i];
		const uint64_t p0 = a & 0xffff, p1 = (a >> 16) & 0xffff, p2 = (a >> 32) & 0xffff, p3 = a >> 48;
		const uint64_t q0 = b & 0xffff, q1 = (b >> 16) & 0xffff, q2 = (b >> 32) & 0xffff, q3 = b >> 48;
		const __m128i v0 = pristine[p0], v1 = pristine[q0], v2 = pristine[p1], v3 = pristine[q1];
		const __m128i v4 = pristine[p2], v5 = pristine[q2], v6 = pristine[p3], v7 = pristine[q3];
		key[p0] = v0; key[q0] = v1; key[p1] = v2; key[q1] = v3;
		key[p2] = v4; key[q2] = v5; key[p3] = v6; key[q3] = v7;
	}
}

static inline void verus_fixkey_pristine_sel_b4(const uint16_t * __restrict sj16, __m128i * __restrict key, const __m128i * __restrict pristine)
{
	typedef uint64_t __attribute__((may_alias)) u64a;
	const u64a *sj = (const u64a *)sj16;
	for (int i = 0; i < 32; i += 4) {
		const uint64_t s0 = sj[i], s1 = sj[i + 1], s2 = sj[i + 2], s3 = sj[i + 3];
		const uint64_t a0 = (s0 >> 5) & 511, b0 = (s0 >> 32) & 511, a1 = (s1 >> 5) & 511, b1 = (s1 >> 32) & 511;
		const uint64_t a2 = (s2 >> 5) & 511, b2 = (s2 >> 32) & 511, a3 = (s3 >> 5) & 511, b3 = (s3 >> 32) & 511;
		const __m128i v0 = pristine[a0], v1 = pristine[b0], v2 = pristine[a1], v3 = pristine[b1];
		const __m128i v4 = pristine[a2], v5 = pristine[b2], v6 = pristine[a3], v7 = pristine[b3];
		key[a0] = v0; key[b0] = v1; key[a1] = v2; key[b1] = v3;
		key[a2] = v4; key[b2] = v5; key[a3] = v6; key[b3] = v7;
	}
}

/* SEL bit 11 (2048): the journal is the round's 64-bit selector (32 of them at sj); the two key positions of
 * a round are its bits 5..13 and 32..40 (keyMask 511). */
static inline void verus_fixkey_pristine_sel(const uint16_t * __restrict sj16, __m128i * __restrict key, const __m128i * __restrict pristine)
{
	typedef uint64_t __attribute__((may_alias)) u64a;
	const u64a *sj = (const u64a *)sj16;
	/* Two rounds at a time, all four loads before the four stores: with load, store, load, store an in-order
	 * core (Cortex-A53) waits at every store for the load in front of it (S8 profile 2026-11-11: this loop
	 * took 13% of the hash that way, the 16-bit version 10%). The order is free: every store writes the
	 * pristine value of its own position. */
	for (int i = 0; i < 32; i += 2) {
		const uint64_t s0 = sj[i], s1 = sj[i + 1];
		const uint64_t a0 = (s0 >> 5) & 511, b0 = (s0 >> 32) & 511, a1 = (s1 >> 5) & 511, b1 = (s1 >> 32) & 511;
		const __m128i v0 = pristine[a0], v1 = pristine[b0], v2 = pristine[a1], v3 = pristine[b1];
		key[a0] = v0; key[b0] = v1; key[a1] = v2; key[b1] = v3;
	}
}

#ifdef VERUS_X2
/* N independent nonces in lockstep (N = 2, 3 or 4); each lane needs its own copy of the key */
/* SEL bit 0: branch-free inner choice in case 0x14, bit 1: same in case 0x18 (variants x2sel, x2sel2),
 * bit 2: case 0x14 entirely branch-free, all 8 steps computed and masked (variant x2sel3, used as SEL 7),
 * bit 3: fused dispatch, one 64-way jump on the pair of cases per round (SEL 8, 9, 11),
 * bit 4: light merge, cases 0/4/8/0x1c as one branch-free body (5 jump targets instead of 8),
 * bit 5: case 0x0c without its 50/50 branch (SEL 16, 32, 48, 19, 35, 51 are instantiated),
 * bit 6: branch-table dispatch, no table load before the case jump resolves (SEL 64, 67, 99; AArch64 only),
 * bit 7 (128): no key journal in the rounds (caller restores from a pristine copy), bit 8 (256, handled in
 * Verus2hash_xN): the two Haraka512 interleaved. Instantiated: 39 128 131 163 227 (+256 needs no new one).
 * bit 9 (512): preload, the four operands every case starts with are loaded before the case jump
 * (instantiated: 512 515 547 640 643 675).
 * bit 10 (1024): fold, the round count of cases 0x14 / 0x18 is part of the case jump, which enters the
 * unrolled rounds at the right place (instantiated: 1152 1155 1187; scan values 1408 1411 1443).
 * bit 11 (2048): lean, selector journal (fixrand must hold 256 bytes) + shorter code in front of the case jump
 * (instantiated: 2176 3200; scan values 2432 3456; needs bit 128).
 * bit 17 (131072): j16, with lean: the old 16-bit journal (fixrand / fixrandex) instead of the selector journal.
 * bit 18 (262144): batch, key restore four rounds per step (verus_fixkey_pristine_b4 / _sel_b4); not a clhash bit.
 * Three lanes (VERUS_X3=1 at run time, Mongoose M1/M2 with 3456 or 265600): verusclhash_port2_2_xN<3, 3200>.
 * bit 12 (4096): threaded dispatch, every case body ends with its own jump to the next case (computed goto,
 * bodies specialised per fold index; needs bit 1024; instantiated: 5248 7296; scan values 5504 7552).
 * bit 13 (8192): goto, one computed-goto case jump per lane with the whole round set-up in front of it (needs
 * 128 + 1024 + 2048). Bits 14-15 (16384, 32768) = A, arms: the arm choices of the last A rounds of cases
 * 0x14 / 0x18 are part of the jump index (2^A copies of their round chains). Bit 16 (65536), dup: lane 0's
 * cases end with their own copy of lane 1's jump. Instantiated: 11392 27776 44160 76928 93312 109696 (two
 * lanes), 11392 27776 44160 (one lane); scan values add 256.
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
