/*
The MIT License (MIT)

Copyright (c) 2016 kste

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Optimized Implementations for Haraka256 and Haraka512
*/
#include "sse2neon.h"
#include <stdio.h>
#include "haraka.h"
//#include <stdint.h>


//uint8x16_t _mm_aesenc_si128 (uint8x16_t a, uint8x16_t RoundKey)
//{
//   return vaesmcq_u8(vaeseq_u8(a, (uint8x16_t){})) ^ RoundKey;
//}
typedef unsigned int uint32_t;



void haraka512_keyed(unsigned char *out, const unsigned char *in, const __m128i *rc) {
  __m128i  tmp, t[4];
  //__m128i tmp;

  struct int64x2x4_t s;
  struct int64x2x4_t n;

  s = vld1q_s64_x4((int64_t *)in);

  //s[0] = LOAD(in);
  //s[1] = LOAD(in + 16);
  //s[2] = LOAD(in + 32);
  //s1[3] = LOAD(in + 48);

  AES4(s.val[0], s.val[1], s.val[2], s.val[3], 0);
  MIX4A(s.val[0], s.val[1], s.val[2], s.val[3]);

  AES4(n.val[0], n.val[1], n.val[2], n.val[3], 8);
  MIX4B(n.val[0], n.val[1], n.val[2], n.val[3]);

  AES4(s.val[0], s.val[1], s.val[2], s.val[3], 16);
  MIX4A(s.val[0], s.val[1], s.val[2], s.val[3]);

  AES4(n.val[0], n.val[1], n.val[2], n.val[3], 24);
  MIX4_LAST(n.val[0], n.val[1], n.val[2], n.val[3]);

  AES4_LAST(n.val[0], s.val[1], s.val[2], n.val[3], 32);


 // s[0] = _mm_xor_si128(s[0], LOAD(in));
 // s[1] = _mm_xor_si128(s[1], LOAD(in + 16));
 // s[2] = _mm_xor_si128(s[2], LOAD(in + 32));
 // s[3] = _mm_xor_si128(s[0], LOAD(in + 48));
  ((uint32_t*)&out[0])[7] = ((uint32_t*)&s.val[0])[10] ^ ((uint32_t*)&in[52])[0];

  //TRUNCSTORE(out, s[0],s[1], s[2], s[3]);
}

/* Two independent haraka512_keyed in one function (two-nonce path, SEL bit 256): the same operations as
 * above for each input, written so the compiler can interleave the two dependency chains (each Haraka is
 * 4 chains of AES rounds; two of them fill a wide core's AES pipes better than one after the other). */
#define HK_AES4(x, r, o) \
  x.val[0] = _mm_aesenc_si128(x.val[0], r[o]);     x.val[1] = _mm_aesenc_si128(x.val[1], r[o + 1]); \
  x.val[2] = _mm_aesenc_si128(x.val[2], r[o + 2]); x.val[3] = _mm_aesenc_si128(x.val[3], r[o + 3]); \
  x.val[0] = _mm_aesenc_si128(x.val[0], r[o + 4]); x.val[1] = _mm_aesenc_si128(x.val[1], r[o + 5]); \
  x.val[2] = _mm_aesenc_si128(x.val[2], r[o + 6]); x.val[3] = _mm_aesenc_si128(x.val[3], r[o + 7]);
/* d = mix(x): the permutation of MIX4A / MIX4B */
#define HK_MIX4(d, x) \
  d.val[0] = vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(d.val[0], 0, x.val[0], 3), 1, x.val[2], 3), 2, x.val[1], 3), 3, x.val[3], 3); \
  d.val[1] = vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(d.val[1], 0, x.val[2], 0), 1, x.val[0], 0), 2, x.val[3], 0), 3, x.val[1], 0); \
  d.val[2] = vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(d.val[2], 0, x.val[2], 1), 1, x.val[0], 1), 2, x.val[3], 1), 3, x.val[1], 1); \
  d.val[3] = vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(d.val[3], 0, x.val[0], 2), 1, x.val[2], 2), 2, x.val[1], 2), 3, x.val[3], 2);
void haraka512_keyed_x2(unsigned char *outA, const unsigned char *inA, const __m128i *rA,
		unsigned char *outB, const unsigned char *inB, const __m128i *rB) {
  struct int64x2x4_t sA, nA, sB, nB;
  __m128i lA, lB;
  sA = vld1q_s64_x4((int64_t *)inA);
  sB = vld1q_s64_x4((int64_t *)inB);
  nA = sA; nB = sB;   /* every lane is overwritten by the first mix; this only avoids reading undefined values */
  HK_AES4(sA, rA, 0)  HK_AES4(sB, rB, 0)
  HK_MIX4(nA, sA)     HK_MIX4(nB, sB)
  HK_AES4(nA, rA, 8)  HK_AES4(nB, rB, 8)
  HK_MIX4(sA, nA)     HK_MIX4(sB, nB)
  HK_AES4(sA, rA, 16) HK_AES4(sB, rB, 16)
  HK_MIX4(nA, sA)     HK_MIX4(nB, sB)
  HK_AES4(nA, rA, 24) HK_AES4(nB, rB, 24)
  /* MIX4_LAST keeps only state 2: lanes (n2[1], n0[1], n3[1], n1[1]); then 2 AES rounds on it */
  lA = vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(sA.val[2], 0, nA.val[2], 1), 1, nA.val[0], 1), 2, nA.val[3], 1), 3, nA.val[1], 1);
  lB = vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(vcopyq_laneq_s32(sB.val[2], 0, nB.val[2], 1), 1, nB.val[0], 1), 2, nB.val[3], 1), 3, nB.val[1], 1);
  lA = _mm_aesenc_si128(lA, rA[34]); lB = _mm_aesenc_si128(lB, rB[34]);
  lA = _mm_aesenc_si128(lA, rA[38]); lB = _mm_aesenc_si128(lB, rB[38]);
  ((uint32_t*)&outA[0])[7] = ((uint32_t*)&lA)[2] ^ ((uint32_t*)&inA[52])[0];
  ((uint32_t*)&outB[0])[7] = ((uint32_t*)&lB)[2] ^ ((uint32_t*)&inB[52])[0];
}
