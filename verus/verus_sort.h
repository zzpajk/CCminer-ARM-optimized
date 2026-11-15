/* "Sorted" multi-nonce Verus hashing (VERUS_SORT=1, experimental). VERUS_SORT_LANES hashes are in flight, each
 * with its own key copy. Every step runs ONE round of FOUR hashes that all need the same case (0, 4, .. 0x1c),
 * as straight-line code, so the 8-way case jump of the round is taken once per four rounds instead of once per
 * round, and its target is known a whole step ahead. A hash's own rounds still run in order, so the result is
 * bit-identical (tests/verus_sorttest.cpp). 28 hashes wait in 8 lists while a step runs, so one list always
 * holds four. Round code: SEL 163 (branch-free arms, restore from the pristine key copy). */
#ifndef VERUS_SORT_H
#define VERUS_SORT_H
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

#define VERUS_SORT_LANES 32

struct verus_slane {
	__m128i acc;
	__m128i pc[4];                  /* the four buffer words of the rounds */
	__m128i *key;                   /* private key copy (>= 552 x 16 bytes) */
	uint64_t i;                     /* next round, 0..32 */
	unsigned char *buf;             /* private 64-byte VerusHashHalf copy, 16-byte aligned */
	uint32_t nonce;
	uint16_t fr[32], fre[32];       /* touched key positions */
};
struct verus_sort {
	struct verus_slane *lane;
	uint32_t cnt[9];                            /* lists 0..7: hashes waiting for that case; 8: finished */
	uint8_t bk[9][VERUS_SORT_LANES + 4];
};

/* Runs steps until cb returns non-zero. cb is called whenever list 8 is not empty: it must take every hash off
 * it (verus_sort_finish), and either restart it (verus_sort_start) or stop the run. */
void verus_sort_run(struct verus_sort *S, int (*cb)(void *), void *ctx, int prefetch);
uint64_t verus_sort_reduce(const __m128i *acc);

/* start hash `id` on its (clean) key with these 15 nonce bytes and queue it */
static inline void verus_sort_start(struct verus_sort *S, int id, const unsigned char *nonce15)
{
	struct verus_slane *s = S->lane + id;
	unsigned char *b = s->buf;
	memcpy(b + 47, b, 16); memcpy(b + 63, b, 1);
	memcpy(b + 32, nonce15, 15);
	const __m128i *a = (const __m128i *)b;
	s->pc[0] = veorq_s64(a[0], a[2]); s->pc[1] = veorq_s64(a[1], a[3]); s->pc[2] = a[2]; s->pc[3] = a[3];
	s->acc = s->key[511 + 2];
	s->i = 0;
	const uint64_t c = ((uint64_t)vgetq_lane_s64(s->acc, 0) >> 2) & 7;
	S->bk[c][S->cnt[c]++] = (uint8_t)id;
}

/* a finished hash: final value, Haraka512, key restored. hash receives the 32-byte result. */
static inline void verus_sort_finish(struct verus_slane *s, unsigned char *hash, const __m128i *pristine)
{
	const uint64_t im = verus_sort_reduce(&s->acc);
	unsigned char *b = s->buf;
	memcpy(b + 47, &im, 8); memcpy(b + 55, &im, 8); memcpy(b + 63, &im, 1);
	haraka512_keyed(hash, b, s->key + (im & 511));
	verus_fixkey_pristine(s->fr, s->fre, s->key, pristine);
}
#endif
#endif
