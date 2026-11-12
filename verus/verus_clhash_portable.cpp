/*
 * This uses veriations of the clhash algorithm for Verus Coin, licensed
 * with the Apache-2.0 open source license.
 * 
 * Copyright (c) 2018 Michael Toutonghi
 * Distributed under the Apache 2.0 software license, available in the original form for clhash
 * here: https://github.com/lemire/clhash/commit/934da700a2a54d8202929a826e2763831bd43cf7#diff-9879d6db96fd29134fc802214163b95a
 * 
 * Original CLHash code and any portions herein, (C) 2017, 2018 Daniel Lemire and Owen Kaser
 * Faster 64-bit universal hashing
 * using carry-less multiplications, Journal of Cryptographic Engineering (to appear)
 *
 * Best used on recent x64 processors (Haswell or better).
 * 
 * This implements an intermediate step in the last part of a Verus block hash. The intent of this step
 * is to more effectively equalize FPGAs over GPUs and CPUs.
 *
 **/


#include "haraka_portable.h"

#include <assert.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#	pragma push_macro("FORCE_INLINE")
#	pragma push_macro("ALIGN_STRUCT")
#	define FORCE_INLINE       static inline __attribute__((always_inline))
#	define ALIGN_STRUCT(x)    __attribute__((aligned(x)))
#else
#	error "Macro name collisions may happens with unknown compiler"
#	define FORCE_INLINE       static inline
#	define ALIGN_STRUCT(x)    __declspec(align(x))
#endif


#ifdef __APPLE__
#include <sys/types.h>
#endif// APPLE

#ifdef _WIN32
#pragma warning (disable : 4146)
#include <intrin.h>
#else
//#include <x86intrin.h>
//#include "arm_neon.h"

#   include "sse2neon.h"
//#include "softaesnc.h"
//typedef int32x4_t __m128i;

#endif //WIN32


/* Ablation switches for timing experiments ONLY (tests/verus_ablate.cpp). They make the hash wrong on
 * purpose to measure how much time one thing costs, i.e. the most that optimising it could ever win.
 * All three are inert unless the matching VERUS_ABL_* macro is defined. */
#if defined(VERUS_ABL_SWITCH_FIXED)
#  define VERUS_ABL_SWITCH(sel, i) ((((i) & 7) << 2))     /* case follows round number: perfectly predictable */
#else
#  define VERUS_ABL_SWITCH(sel, i) ((sel) & 0x1c)
#endif
#if defined(VERUS_ABL_INNER_FIXED)
#  define VERUS_ABL_INNER(sel, rounds) ((rounds) & 1)      /* alternating: predictable inner branch */
#else
#  define VERUS_ABL_INNER(sel, rounds) ((sel) & (0x10000000L << (rounds)))
#endif
#if defined(VERUS_ABL_NODIV)
#  define VERUS_ABL_MOD(a, b) ((a) ^ (b))                  /* no hardware divide */
#else
#  define VERUS_ABL_MOD(a, b) ((a) % (b))
#endif

#define AES2(s0, s1, rci) \
  s0 = _mm_aesenc_si128(s0, rc[rci]); \
  s1 = _mm_aesenc_si128(s1, rc[rci + 1]); \
  s0 = _mm_aesenc_si128(s0, rc[rci + 2]); \
  s1 = _mm_aesenc_si128(s1, rc[rci + 3]);

FORCE_INLINE __m128i _mm_clmulepi64_si128_emu(const __m128i a, const __m128i &b, int imm)
{
	__m128i result;
   
 // uint64x2_t aa = *(uint64x2_t*)&a;
 // uint64x2_t bb = *(uint64x2_t*)&b;
  
 result = (__m128i)vmull_p64(vgetq_lane_u64(a, 1), vgetq_lane_u64(b,0)); 

	return result;

}

FORCE_INLINE __m128i _mm_mulhrs_epi16_emu(__m128i _a, __m128i _b)
{
//	int16_t result[8];
//	int16_t *a = (int16_t*)&_a, *b = (int16_t*)&_b;
//	for (int i = 0; i < 8; i++)
//	{
//		result[i] = (int16_t)((((int32_t)(a[i]) * (int32_t)(b[i])) + 0x4000) >> 15);
//	}

#ifdef VERUS_ABL_NOMULHRS
	return veorq_s64(_a,_b);   /* timing experiment only */
#else
	return vqrdmulhq_s16(_a,_b); //*(__m128i *)result;
#endif
}

 __m128i _mm_set_epi64x_emu(uint64_t hi, uint64_t lo)
{
	__m128i result;
	((uint64_t *)&result)[0] = lo;
	((uint64_t *)&result)[1] = hi;
	return result;
}

 __m128i _mm_cvtsi64_si128_emu(uint64_t lo)
{
	__m128i result;
	((uint64_t *)&result)[0] = lo;
	((uint64_t *)&result)[1] = 0;
	return result;
}

 int64_t _mm_cvtsi128_si64_emu(const __m128i &a)
{
	return *(int64_t *)&a;
}

 int32_t _mm_cvtsi128_si32_emu(__m128i &a)
{
	return *(int32_t *)&a;
}

 FORCE_INLINE __m128i _mm_cvtsi32_si128_emu(uint32_t lo)
{
//	__m128i result;
//	((uint32_t *)&result)[0] = lo;
//	((uint32_t *)&result)[1] = 0;
//	((uint64_t *)&result)[1] = 0;
return vreinterpretq_m128i_s32(vsetq_lane_s32(lo, vdupq_n_s32(0), 0));
	/*
	const __m128i testresult = _mm_cvtsi32_si128(lo);
	if (!memcmp(&testresult, &result, 16))
	{
	printf("_mm_cvtsi32_si128_emu: Portable version passed!\n");
	}
	else
	{
	printf("_mm_cvtsi32_si128_emu: Portable version failed!\n");
	}
	*/

//	return result;
}
typedef uint8_t u_char;

__m128i _mm_setr_epi8_emu(u_char c0, u_char c1, u_char c2, u_char c3, u_char c4, u_char c5, u_char c6, u_char c7, u_char c8, u_char c9, u_char c10, u_char c11, u_char c12, u_char c13, u_char c14, u_char c15)
{
	__m128i result;
	((uint8_t *)&result)[0] = c0;
	((uint8_t *)&result)[1] = c1;
	((uint8_t *)&result)[2] = c2;
	((uint8_t *)&result)[3] = c3;
	((uint8_t *)&result)[4] = c4;
	((uint8_t *)&result)[5] = c5;
	((uint8_t *)&result)[6] = c6;
	((uint8_t *)&result)[7] = c7;
	((uint8_t *)&result)[8] = c8;
	((uint8_t *)&result)[9] = c9;
	((uint8_t *)&result)[10] = c10;
	((uint8_t *)&result)[11] = c11;
	((uint8_t *)&result)[12] = c12;
	((uint8_t *)&result)[13] = c13;
	((uint8_t *)&result)[14] = c14;
	((uint8_t *)&result)[15] = c15;

	/*
	const __m128i testresult = _mm_setr_epi8(c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15);
	if (!memcmp(&testresult, &result, 16))
	{
	printf("_mm_setr_epi8_emu: Portable version passed!\n");
	}
	else
	{
	printf("_mm_setr_epi8_emu: Portable version failed!\n");
	}
	*/

	return result;
}

#define _mm_srli_si128_emu(a, imm) \
({ \
	__m128i ret; \
	if ((imm) <= 0) { \
		ret = a; \
	} \
	else if ((imm) > 15) { \
		ret = _mm_setzero_si128(); \
	} \
	else { \
		ret = vreinterpretq_m128i_s8(vextq_s8(vreinterpretq_s8_m128i(a), vdupq_n_s8(0), (imm))); \
	} \
	ret; \
})

 __m128i _mm_srli_si128_emu_old(__m128i a, int imm8)
{
	unsigned char result[16];
	uint8_t shift = imm8 & 0xff;
	if (shift > 15) shift = 16;

	int i;
	for (i = 0; i < (16 - shift); i++)
	{
		result[i] = ((unsigned char *)&a)[shift + i];
	}
	for (; i < 16; i++)
	{
		result[i] = 0;
	}

	/*
	const __m128i tmp1 = _mm_load_si128(&a);
	__m128i testresult = _mm_srli_si128(tmp1, imm8);
	if (!memcmp(&testresult, result, 16))
	{
	printf("_mm_srli_si128_emu: Portable version passed!\n");
	}
	else
	{
	printf("_mm_srli_si128_emu: Portable version failed! val: %lx%lx imm: %x emu: %lx%lx, intrin: %lx%lx\n",
	*((uint64_t *)&a + 1), *(uint64_t *)&a,
	imm8,
	*((uint64_t *)result + 1), *(uint64_t *)result,
	*((uint64_t *)&testresult + 1), *(uint64_t *)&testresult);
	}
	*/

	return *(__m128i *)result;
}

 __m128i _mm_xor_si128_emu(__m128i a, __m128i b)
{
	return a^ b; //vreinterpretq_m128i_s32( veorq_s32(vreinterpretq_s32_m128i(a), vreinterpretq_s32_m128i(b)) );

}

 __m128i _mm_load_si128_emu(const void *p)
{

return vreinterpretq_m128i_s32(vld1q_s32((int32_t *)p));
//	return *(__m128i *)p;
}

 void _mm_store_si128_emu(void *p, __m128i val)
{
	
  vst1q_s32((int32_t*) p, vreinterpretq_s32_m128i(val));
 // *(__m128i *)p = val;
}

__m128i _mm_shuffle_epi8_emu(__m128i a, __m128i b)
{
	__m128i result;
	for (int i = 0; i < 16; i++)
	{
		if (((uint8_t *)&b)[i] & 0x80)
		{
			((uint8_t *)&result)[i] = 0;
		}
		else
		{
			((uint8_t *)&result)[i] = ((uint8_t *)&a)[((uint8_t *)&b)[i] & 0xf];
		}
	}

	/*
	const __m128i tmp1 = _mm_load_si128(&a);
	const __m128i tmp2 = _mm_load_si128(&b);
	__m128i testresult = _mm_shuffle_epi8(tmp1, tmp2);
	if (!memcmp(&testresult, &result, 16))
	{
	printf("_mm_shuffle_epi8_emu: Portable version passed!\n");
	}
	else
	{
	printf("_mm_shuffle_epi8_emu: Portable version failed!\n");
	}
	*/

	return result;
}

// portable
__m128i lazyLengthHash_port(uint64_t keylength, uint64_t length) {
	const __m128i lengthvector = _mm_set_epi64x_emu(keylength, length);
	const __m128i clprod1 = _mm_clmulepi64_si128_emu(lengthvector, lengthvector, 0x10);
	return clprod1;
}

// modulo reduction to 64-bit value. The high 64 bits contain garbage, see precompReduction64
__m128i precompReduction64_si128_port(__m128i A) {

	//const __m128i C = _mm_set_epi64x(1U,(1U<<4)+(1U<<3)+(1U<<1)+(1U<<0)); // C is the irreducible poly. (64,4,3,1,0)
	const __m128i C = _mm_cvtsi64_si128_emu((1U << 4) + (1U << 3) + (1U << 1) + (1U << 0));
	__m128i Q2 = _mm_clmulepi64_si128_emu(A, C, 0x01);
	__m128i Q3 = _mm_shuffle_epi8(_mm_setr_epi8(0, 27, 54, 45, 108, 119, 90, 65, (char)216, (char)195, (char)238, (char)245, (char)180, (char)175, (char)130, (char)153),
		_mm_srli_si128(Q2, 8));
	__m128i Q4 = _mm_xor_si128_emu(Q2, A);
	const __m128i final = _mm_xor_si128_emu(Q3, Q4);
	return final;/// WARNING: HIGH 64 BITS SHOULD BE ASSUMED TO CONTAIN GARBAGE
}

uint64_t precompReduction64_port(__m128i A) {
	__m128i tmp = precompReduction64_si128_port(A);
	return _mm_cvtsi128_si64_emu(tmp);
}

uint8x16_t _mm_aesenc_si128 (uint8x16_t a, uint8x16_t RoundKey)
{
    return vaesmcq_u8(vaeseq_u8(a, (uint8x16_t){})) ^ RoundKey;
}


// verus intermediate hash extra
/* JOURNAL = true: the original code, which saves the old value of both key positions every round so
 * FixKey() can undo the mutations afterwards. JOURNAL = false (variant "pristine"): no saves; the caller
 * restores the touched positions from a pristine copy of the key instead (64 fewer vector stores per hash). */
template<bool JOURNAL, bool PRE = false>
FORCE_INLINE __m128i verusclmul_repeat_port2_2_t(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, uint16_t * __restrict fixrand, 
										uint16_t * __restrict fixrandex, __m128i *g_prand, __m128i *g_prandex)
{
	__m128i const *pbuf, *pbsf;
   const __m128i pbuf_copy[4] = {_mm_xor_si128(buf[0],buf[2]), _mm_xor_si128(buf[1],buf[3]), buf[2], buf[3]}; 
	/*
	std::cout << "Random key start: ";
	std::cout << LEToHex(*randomsource) << ", ";
	std::cout << LEToHex(*(randomsource + 1));
	std::cout << std::endl;
	*/

	// divide key mask by 16 from bytes to __m128i
	//keyMask >>= 4;

	// the random buffer must have at least 32 16 byte dwords after the keymask to work with this
	// algorithm. we take the value from the last element inside the keyMask + 2, as that will never
	// be used to xor into the accumulator before it is hashed with other values first
	__m128i acc = _mm_load_si128_emu(randomsource + (keyMask + 2));

	for (uint64_t i = 0; i < 32; i++)
	{
		//std::cout << "LOOP " << i << " acc: " << LEToHex(acc) << std::endl;

		const uint64_t selector = _mm_cvtsi128_si64_emu(acc);
		const uint64_t selector_fudge = selector & 1 ? 1 : -1 ;

		// get two random locations in the key, which will be mutated and swapped
		fixrand[i]  = (uint16_t) ((selector >> 5) & keyMask);
		fixrandex[i] = (uint16_t) ((selector >>32) & keyMask);
		__m128i *prand = randomsource + fixrand[i];
		__m128i *prandex = randomsource + fixrandex[i];
		if (JOURNAL) {
			g_prand[i] = *prand;
			g_prandex[i] = *prandex;
		}



		// select random start and order of pbuf processing
		pbuf = pbuf_copy + (selector & 3);
		pbsf = pbuf - selector_fudge;
		/* PRE: load the four operands every case starts with before the case jump (see SEL bit 512) */
		__m128i preX, preY, preB, preS;
		if (PRE) { preX = _mm_load_si128_emu(prand); preY = _mm_load_si128_emu(prandex); preB = _mm_load_si128_emu(pbuf); preS = _mm_load_si128_emu(pbsf); }
		else { preX = preY = preB = preS = _mm_setzero_si128(); }
#define VPRE_X (PRE ? preX : _mm_load_si128_emu(prand))
#define VPRE_Y (PRE ? preY : _mm_load_si128_emu(prandex))
#define VPRE_B (PRE ? preB : _mm_load_si128_emu(pbuf))
#define VPRE_S (PRE ? preS : _mm_load_si128_emu(pbsf))
  
   		//fixrand[i] = prand_idx;
		//fixrandex[i] = prandex_idx;


		switch (VERUS_ABL_SWITCH(selector, i))
		{
		case 0:
		{
			const __m128i temp1 = VPRE_Y;
			const __m128i temp2 = VPRE_S;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			acc = _mm_xor_si128_emu(clprod1, acc);

			/*
			std::cout << "temp1: " << LEToHex(temp1) << std::endl;
			std::cout << "temp2: " << LEToHex(temp2) << std::endl;
			std::cout << "add1: " << LEToHex(add1) << std::endl;
			std::cout << "clprod1: " << LEToHex(clprod1) << std::endl;
			std::cout << "acc: " << LEToHex(acc) << std::endl;
			*/

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = VPRE_X;
			_mm_store_si128_emu(prand, tempa2);

			const __m128i temp22 = VPRE_B;
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			acc = _mm_xor_si128_emu(clprod12, acc);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
			//const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			*prandex  = _mm_xor_si128_emu(tempb1, temp12);
			//_mm_store_si128_emu(prandex, tempb2);
			break;
		}
		case 4:
		{
			const __m128i temp1 = VPRE_X;
			const __m128i temp2 = VPRE_B;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			acc = _mm_xor_si128_emu(clprod1, acc);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			acc = _mm_xor_si128_emu(clprod2, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = VPRE_Y;
			_mm_store_si128_emu(prandex, tempa2);

			const __m128i temp22 = VPRE_S;
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			acc = _mm_xor_si128_emu(add12, acc);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prand, tempb2);
			break;
		}
		case 8:
		{
			const __m128i temp1 = VPRE_Y;
			const __m128i temp2 = VPRE_B;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			acc = _mm_xor_si128_emu(add1, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = VPRE_X;
			_mm_store_si128_emu(prand, tempa2);

			const __m128i temp22 = VPRE_S;
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			acc = _mm_xor_si128_emu(clprod12, acc);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			acc = _mm_xor_si128_emu(clprod22, acc);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandex, tempb2);
			break;
		}
		case 0xc:
		{
			const __m128i temp1 = VPRE_X;
			const __m128i temp2 = VPRE_S;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);

			// cannot be zero here
			const int32_t divisor = (uint32_t)selector;

			acc = _mm_xor_si128_emu(add1, acc);

			const int64_t dividend = _mm_cvtsi128_si64_emu(acc);
                        asm(".global __use_realtime_division\n");
			const __m128i modulo = _mm_cvtsi32_si128_emu(VERUS_ABL_MOD(dividend, divisor));
			acc = _mm_xor_si128_emu(modulo, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			if (dividend & 1)
			{
				const __m128i temp12 = VPRE_Y;
				_mm_store_si128_emu(prandex, tempa2);

				const __m128i temp22 = VPRE_B;
				const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
				const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
				acc = _mm_xor_si128_emu(clprod12, acc);
				const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
				acc = _mm_xor_si128_emu(clprod22, acc);

				const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
				const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
				_mm_store_si128_emu(prand, tempb2);
			}
			else
			{
				*prand = VPRE_Y;
				_mm_store_si128_emu(prandex, tempa2);
				const __m128i tempb4 = VPRE_B;
				acc = _mm_xor_si128_emu(tempb4, acc);
			}
			break;
		}
		case 0x10:
		{
			// a few AES operations
			const __m128i *rc = prand;
			__m128i tmp;

			__m128i temp1 = VPRE_S;
			__m128i temp2 = VPRE_B;

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			acc = _mm_xor_si128_emu(temp1, acc);
			acc = _mm_xor_si128_emu(temp2, acc);

			const __m128i tempa1 = VPRE_X;
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);

			*prand = VPRE_Y;
			*prandex = _mm_xor_si128_emu(tempa1, tempa2);
			break;
		}
		case 0x14:
		{
			// we'll just call this one the monkins loop, inspired by Chris
			const __m128i *buftmp = pbsf;
			__m128i tmp; // used by MIX2

			int64_t rounds = selector >> 61; // loop randomly between 1 and 8 times
			__m128i *rc = prand;
			uint64_t aesround = 0;
			__m128i onekey, temp1a, temp1b, temp2a, temp2b;

//			do
//			{
//				//std::cout << "acc: " << LEToHex(acc) << ", round check: " << LEToHex((selector & (0x10000000 << rounds))) << std::endl;
//
//				// note that due to compiler and CPUs, we expect this to do:
//				// if (selector & ((0x10000000 << rounds) & 0xffffffff) if rounds != 3 else selector & 0xffffffff80000000):
//				if (selector & ((uint64_t)0x10000000 << rounds))
//				{
//					onekey = _mm_load_si128_emu(rc++);
//					const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : buftmp);
//					const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
//					const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
//					acc = _mm_xor_si128_emu(clprod1, acc);
//				}
//				else
//				{
//					onekey = _mm_load_si128_emu(rc++);
//					__m128i temp2 = _mm_load_si128_emu(rounds & 1 ? buftmp : pbuf);
//					const uint64_t roundidx = aesround++ << 2;
//					AES2(onekey, temp2, roundidx);
//
//					/*
//					std::cout << " onekey1: " << LEToHex(onekey) << std::endl;
//					std::cout << "  temp21: " << LEToHex(temp2) << std::endl;
//					std::cout << "roundkey: " << LEToHex(rc[roundidx]) << std::endl;
//
//					aesenc((unsigned char *)&onekey, (unsigned char *)&(rc[roundidx]));
//
//					std::cout << "onekey2: " << LEToHex(onekey) << std::endl;
//					std::cout << "roundkey: " << LEToHex(rc[roundidx + 1]) << std::endl;
//
//					aesenc((unsigned char *)&temp2, (unsigned char *)&(rc[roundidx + 1]));
//
//					std::cout << " temp22: " << LEToHex(temp2) << std::endl;
//					std::cout << "roundkey: " << LEToHex(rc[roundidx + 2]) << std::endl;
//
//					aesenc((unsigned char *)&onekey, (unsigned char *)&(rc[roundidx + 2]));
//
//					std::cout << "onekey2: " << LEToHex(onekey) << std::endl;
//
//					aesenc((unsigned char *)&temp2, (unsigned char *)&(rc[roundidx + 3]));
//
//					std::cout << " temp22: " << LEToHex(temp2) << std::endl;
//					*/
//
//					MIX2_EMU(onekey, temp2);
//
//					/*
//					std::cout << "onekey3: " << LEToHex(onekey) << std::endl;
//					*/
//
//					acc = _mm_xor_si128_emu(onekey, acc);
//					acc = _mm_xor_si128_emu(temp2, acc);
//				}
//			} while (rounds--);
//
#pragma clang loop unroll(full)
                        //for ( int64_t count = 1; count <= 8; count++ )
                        for ( uint64_t count = 8; count--;  )
                        {
                                if ( rounds >= 0 )
                                {
                                                onekey = _mm_load_si128_emu(rc++);
                                                //printf("selector %" PRIu64 "\n", selector);

                                                if (VERUS_ABL_INNER(selector, rounds))
                                                {
                                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : pbsf);  //rounds is odd
                                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
                                                        const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                                        acc = _mm_xor_si128_emu(clprod1, acc);
                                                }
                                                else
                                                {
                                                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbsf : pbuf);  //rounds is odd
                                                        const uint64_t roundidx = aesround++ << 2;
                                                        AES2(onekey, temp2, roundidx);

                                                        MIX2_EMU(onekey, temp2);

                                                        acc ^= onekey ^ temp2;
                                                }
                                rounds--;
                                }
                        }


			const __m128i tempa1 = VPRE_X;
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);
			*prand = VPRE_Y;
			*prandex = _mm_xor_si128_emu(tempa1, tempa2);

			break;
		}
		case 0x18:
   {   
             const __m128i *buftmp = pbsf;
                __m128i tmp; // used by MIX2

                int64_t rounds = selector >> 61; // loop randomly between 1 and 8 times
                __m128i *rc = prand;
                __m128i onekey;

//                do
//                {
//                    if (selector & (((uint64_t)0x10000000) << rounds))
//                    {
//                        onekey = _mm_load_si128_emu(rc++);
//                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : buftmp);
//                        onekey = _mm_xor_si128_emu(onekey, temp2);
//                        // cannot be zero here, may be negative
//                        const int32_t divisor = (uint32_t)selector;
//                        const int64_t dividend = _mm_cvtsi128_si64_emu(onekey);
//                        const __m128i modulo = _mm_cvtsi32_si128_emu(dividend % divisor);
//                        acc = _mm_xor_si128_emu(modulo, acc);
//                    }
//                    else
//                    {
//                        onekey = _mm_load_si128_emu(rc++);
//                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? buftmp : pbuf);
//                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
//                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
//                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(acc, onekey);
//                        acc = _mm_xor_si128_emu(clprod2, acc);
//                    }
//                } while (rounds--);
  
#pragma clang loop unroll(full)
                for ( uint64_t count = 8; count--;  )
                {
                        if ( rounds >= 0 )
                        {
                                    onekey = _mm_load_si128_emu(rc++);
                                    if (VERUS_ABL_INNER(selector, rounds))
                                    {
                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : pbsf );
                                        onekey = _mm_xor_si128_emu(onekey, temp2);
                                        // cannot be zero here, may be negative
  		                        const int32_t divisor = (uint32_t)selector;
                                        const int64_t dividend = _mm_cvtsi128_si64(onekey);
                                        asm(".global __use_realtime_division\n");
                                        const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor));
                                        acc = _mm_xor_si128_emu(modulo, acc);
                                    }
                                    else
                                    {
                                        const __m128i temp4 = _mm_load_si128_emu(rounds & 1 ? pbsf : pbuf);
                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp4);
                                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(acc, onekey);
                                        acc = _mm_xor_si128_emu(clprod2, acc);
                                    }
                                    rounds--;
                        }
                }


                *prand = _mm_xor_si128_emu(VPRE_Y, acc);
                _mm_store_si128_emu(prandex, onekey);
                break;
            }
		default: 
		{
			const __m128i temp1 = VPRE_B;
			const __m128i temp2 = VPRE_Y;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			acc = _mm_xor_si128_emu(clprod1, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = VPRE_X;
			_mm_store_si128_emu(prand, tempa2);

			acc = _mm_xor_si128_emu(tempa3, acc);
			const __m128i temp4 = VPRE_S;
			acc = _mm_xor_si128(temp4, acc);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandex, tempb2);
		//	break;
		}
		}

   
	}
	return acc;
}
#undef VPRE_X
#undef VPRE_Y
#undef VPRE_B
#undef VPRE_S

__m128i __verusclmulwithoutreduction64alignedrepeat_port2_2(__m128i *randomsource, const __m128i buf[4], uint64_t keyMask, uint16_t * __restrict fixrand, 
										uint16_t * __restrict fixrandex, __m128i *g_prand, __m128i *g_prandex)
{
	return verusclmul_repeat_port2_2_t<true>(randomsource, buf, keyMask, fixrand, fixrandex, g_prand, g_prandex);
}

#ifdef VERUS_STATS
/* statistics build only: selector of every round of the last x2 call, one row per lane */
uint64_t verus_dbg_sel[2][32];
uint32_t verus_dbg_n;
#endif
#ifdef VERUS_X2
/* One round of the 32-round clhash loop, identical to the loop body of
 * __verusclmulwithoutreduction64alignedrepeat_port2_2 above (generated from it, not rewritten), so two
 * independent nonces can be advanced in lockstep and the out-of-order core can overlap their dependency
 * chains. Each lane has its own key copy: a nonce mutates the key while hashing. */
/* SEL bit 4 (16), "light merge": cases 0, 4, 8 and 0x1c are one template,
 *   X = *A, Y = *B, P, Q = the two buffer words;  acc ^= F1(X, P);  *B = mulhrs(acc, X) ^ X;
 *   acc ^= F2(Y, Q);  *A = mulhrs(acc, Y) ^ Y
 * with F(v, p) = clmul(v ^ p) (CL), clmul(v ^ p) ^ clmul(p) (CL2) or v ^ p (LIN):
 *   case 0:    A = prandex, P = pbsf, F1 = CL,   F2 = CL
 *   case 4:    A = prand,   P = pbuf, F1 = CL2,  F2 = LIN
 *   case 8:    A = prandex, P = pbuf, F1 = LIN,  F2 = CL2
 *   case 0x1c: A = prandex, P = pbuf, F1 = CL,   F2 = LIN
 * so they run as ONE branch-free body (pointer choice by csel, F choice by masks from this table) and the
 * case jump has 5 targets instead of 8, one of them taken half the time. Indirect predictors do better on
 * that (expected mispredicts per round ~0.69 instead of ~0.88 for a last-target style predictor; Exynos
 * Mongoose's VPC predictor and M5's mispredict recovery buffer both cost more per extra target).
 * Rows: mask LIN for F1, mask "add clmul(P)" for F1, same two for F2. */
static const uint64_t verus_light_mask[4][8] __attribute__((aligned(64))) = {
	{ 0, 0,  0, 0,  0, 0,  0, 0 },                                   /* case 0 */
	{ 0, 0,  ~0ULL, ~0ULL,  ~0ULL, ~0ULL,  0, 0 },                   /* case 4 */
	{ ~0ULL, ~0ULL,  0, 0,  0, 0,  ~0ULL, ~0ULL },                   /* case 8 */
	{ 0, 0,  0, 0,  ~0ULL, ~0ULL,  0, 0 },                           /* case 0x1c */
};
FORCE_INLINE __m128i verus_light_f(const __m128i v, const __m128i p, const uint64_t *m)
{
	const __m128i cl = _mm_clmulepi64_si128_emu(v, v, 0x10);
	const __m128i cp = _mm_clmulepi64_si128_emu(p, p, 0x10);
	const uint64x2_t lin = vld1q_u64(m), addp = vld1q_u64(m + 2);
	return vreinterpretq_s64_u64(veorq_u64(vbslq_u64(lin, vreinterpretq_u64_s64(v), vreinterpretq_u64_s64(cl)),
		vandq_u64(addp, vreinterpretq_u64_s64(cp))));
}

/* FIXC >= 0: the case is known at compile time (fused dispatch, SEL bit 3), so the switch folds away. */
/* fold index of a selector: case | rounds << 3 (two instructions on AArch64) */
FORCE_INLINE uint64_t verus_fold_index(uint64_t selector)
{
#if defined(__aarch64__)
	uint64_t x;
	__asm__("lsr %0, %1, #58\n\tbfxil %0, %1, #2, #3" : "=&r"(x) : "r"(selector));
	return x;
#else
	return ((selector >> 58) & ~(uint64_t)7) | ((selector >> 2) & 7);
#endif
}
typedef uint64_t __attribute__((may_alias)) verus_u64_alias;
template<int SEL, int FIXC = -1>
FORCE_INLINE void verus_round_port2_2(__m128i &acc, const uint64_t i, __m128i *randomsource,
		const __m128i *pbuf_copy, uint64_t keyMask, uint16_t * __restrict fixrand,
		uint16_t * __restrict fixrandex, __m128i *g_prand, __m128i *g_prandex, uint64_t presel = 0,
		__m128i *xprand = nullptr, __m128i *xprandex = nullptr, const __m128i *xpbuf = nullptr, const __m128i *xpbsf = nullptr)
{
	__m128i const *pbuf, *pbsf;

		//std::cout << "LOOP " << i << " acc: " << LEToHex(acc) << std::endl;

		/* threaded dispatch (4096): the caller already moved the selector to a general register for its jump */
		/* goto dispatch (8192): the caller also wrote the journal and computed prand, prandex, pbuf, pbsf */
		const uint64_t selector = (SEL & (4096 | 8192)) ? presel : (uint64_t)_mm_cvtsi128_si64_emu(acc);
#ifdef VERUS_STATS
		verus_dbg_sel[(verus_dbg_n++) & 1][i] = selector;
#endif
		const uint64_t selector_fudge = selector & 1 ? 1 : -1 ;

		// get two random locations in the key, which will be mutated and swapped
		/* SEL bit 11 (2048), "lean": fewer instructions in front of the case jump (the same work, bit-exact):
		 * - the journal of touched key positions is ONE 64-bit store of the selector per round (both
		 *   positions are bit fields of it) instead of two 16-bit stores; verus_fixkey_pristine_sel() takes
		 *   the positions from it. fixrand must then hold 32 * 8 bytes; fixrandex is not used.
		 * - pbsf = pbuf -/+ 1 is index (selector & 3) ^ 1 of the same four words
		 * - with fold, the jump index is two instructions (lsr #58 + bfxil) */
		if (SEL & 8192) {
		} else if (SEL & 2048) {
			*(verus_u64_alias *)(fixrand + 4 * i) = selector;
		} else {
		fixrand[i]  = (uint16_t) ((selector >> 5) & keyMask);
		fixrandex[i] = (uint16_t) ((selector >>32) & keyMask);
		}
		__m128i *prand = (SEL & 8192) ? xprand : randomsource + ((SEL & 2048) ? ((selector >> 5) & keyMask) : (uint64_t)fixrand[i]);
		__m128i *prandex = (SEL & 8192) ? xprandex : randomsource + ((SEL & 2048) ? ((selector >> 32) & keyMask) : (uint64_t)fixrandex[i]);
		if (!(SEL & 128)) {   /* bit 128: no journal, the caller restores from a pristine key copy */
			g_prand[i] = *prand;
			g_prandex[i] = *prandex;
		}



		// select random start and order of pbuf processing
		pbuf = (SEL & 8192) ? xpbuf : pbuf_copy + (selector & 3);
		pbsf = (SEL & 8192) ? xpbsf : (SEL & 2048) ? pbuf_copy + ((selector & 3) ^ 1) : pbuf - selector_fudge;
		/* SEL bit 9 (512), "preload": every case starts by reading *prand, *prandex, *pbuf and *pbsf (before
		 * any store of the round), so they are loaded here, BEFORE the unpredictable case jump. After a
		 * mispredict the case then starts with its operands ready instead of waiting for the loads. */
		__m128i preX, preY, preB, preS;
		if (SEL & 512) { preX = _mm_load_si128_emu(prand); preY = _mm_load_si128_emu(prandex); preB = _mm_load_si128_emu(pbuf); preS = _mm_load_si128_emu(pbsf); }
		else { preX = preY = preB = preS = _mm_setzero_si128(); }
#define VPRE_X ((SEL & 512) ? preX : _mm_load_si128_emu(prand))
#define VPRE_Y ((SEL & 512) ? preY : _mm_load_si128_emu(prandex))
#define VPRE_B ((SEL & 512) ? preB : _mm_load_si128_emu(pbuf))
#define VPRE_S ((SEL & 512) ? preS : _mm_load_si128_emu(pbsf))
  
   		//fixrand[i] = prand_idx;
		//fixrandex[i] = prandex_idx;


		uint64_t sw = (uint64_t)VERUS_ABL_SWITCH(selector, i);
		if (SEL & 16) {
			/* light merge: cases 0, 4, 8, 0x1c (index 0, 1, 2, 7 -> bit mask 0x87) all jump to case 0 */
			sw = ((0x87u >> ((sw >> 2) & 7)) & 1) ? 0 : sw;
		}
		/* SEL bit 10 (1024), "fold": the round count of cases 0x14 and 0x18 (selector >> 61, 1..8 rounds) is
		 * part of the jump index, and the jump enters the unrolled round chain at the right round (Duff's
		 * device: round r is followed by r-1 .. 0). The jump mispredicts 7 times in 8 anyway; the separate,
		 * equally unpredictable loop exit is gone, and inside a round the selector bit and the buffer word
		 * are constants. Round r of R reads the key word prand[R - r], as the original rc++ does. */
/* with bit 4096 (threaded dispatch in verusclhash_port2_2_xN) FIXC >= 0 is a fold index: case | rounds << 3 */
#define VERUS_FOLD ((SEL & 1024) && (FIXC < 0 || (SEL & (4096 | 8192))))
#define VERUS_CASE(c) (VERUS_FOLD ? (uint64_t)((c) >> 2) : (uint64_t)(c))
#define VERUS_CASEX(c, r) (VERUS_FOLD ? (uint64_t)(((c) >> 2) | ((r) << 3)) : (uint64_t)(0x1000 + (c) * 8 + (r)))   /* dead labels when not folding */
#define VERUS_CASEL(c) (VERUS_FOLD ? (uint64_t)(0x2000 + (c)) : (uint64_t)(c))                                 /* dead label when folding */
#define VERUS_CASE8(c) case VERUS_CASE(c): case VERUS_CASEX(c, 1): case VERUS_CASEX(c, 2): case VERUS_CASEX(c, 3): \
		case VERUS_CASEX(c, 4): case VERUS_CASEX(c, 5): case VERUS_CASEX(c, 6): case VERUS_CASEX(c, 7)
		/* dead labels when not folding; with them all 64 index values have a label (no range check) */
#define VERUS_CASED(r) (VERUS_FOLD ? (uint64_t)(7 | ((r) << 3)) : (uint64_t)(0x3000 + (r)))
		/* Set only by the entry stubs of cases 0x14 / 0x18 (so nothing is added in front of the jump for the
		 * other cases): entering at round r means R == r, so the last round's key word is prand + r. */
		const __m128i *f_end = prand;              /* key word of the last round (round 0) */
		uint64_t f_aes = 0;                        /* AES arms executed so far in case 0x14 */
		__m128i f_ok = acc;                        /* 'onekey' of the last round in case 0x18 */
		/* index = case | rounds << 3, as lsr #58 + bfxil (two instructions in front of the table load) */
		uint64_t fidx = ((selector >> 58) & ~(uint64_t)7) | ((selector >> 2) & 7);
#if defined(__aarch64__)
		if (VERUS_FOLD && (SEL & 2048) && FIXC < 0) {
			__asm__("lsr %0, %1, #58\n\tbfxil %0, %1, #2, #3" : "=&r"(fidx) : "r"(selector));
			if (fidx > 63) __builtin_unreachable();
		}
#endif
		switch (FIXC >= 0 ? (uint64_t)FIXC : VERUS_FOLD ? fidx : sw)
		{
		VERUS_CASE8(0):
		if (SEL & 16) {
			const uint64_t c = (selector >> 2) & 3;          /* 0: case 0, 1: case 4, 2: case 8, 3: case 0x1c */
			__m128i *pa = (c == 1) ? prand : prandex;
			__m128i *pb = (c == 1) ? prandex : prand;
			const __m128i *pp = (c == 0) ? pbsf : pbuf;
			const __m128i *pq = (c == 0) ? pbuf : pbsf;
			const uint64_t *mk = verus_light_mask[c];
			/* the buffer words never alias the key, so all loads go first; Y is read before *B is written, as
			 * in every original case (this also keeps the prand == prandex corner identical) */
			const __m128i X = _mm_load_si128_emu(pa);
			const __m128i Y = _mm_load_si128_emu(pb);
			const __m128i P = _mm_load_si128_emu(pp);
			const __m128i Q = _mm_load_si128_emu(pq);
			acc = _mm_xor_si128_emu(acc, verus_light_f(_mm_xor_si128_emu(X, P), P, mk));
			_mm_store_si128_emu(pb, _mm_xor_si128_emu(_mm_mulhrs_epi16_emu(acc, X), X));
			acc = _mm_xor_si128_emu(acc, verus_light_f(_mm_xor_si128_emu(Y, Q), Q, mk + 4));
			_mm_store_si128_emu(pa, _mm_xor_si128_emu(_mm_mulhrs_epi16_emu(acc, Y), Y));
			break;
		}
		{
			const __m128i temp1 = VPRE_Y;
			const __m128i temp2 = VPRE_S;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			acc = _mm_xor_si128_emu(clprod1, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = VPRE_X;
			_mm_store_si128_emu(prand, tempa2);

			const __m128i temp22 = VPRE_B;
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			acc = _mm_xor_si128_emu(clprod12, acc);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
			*prandex  = _mm_xor_si128_emu(tempb1, temp12);
			break;
		}
		VERUS_CASE8(4):
		{
			const __m128i temp1 = VPRE_X;
			const __m128i temp2 = VPRE_B;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			acc = _mm_xor_si128_emu(clprod1, acc);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			acc = _mm_xor_si128_emu(clprod2, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = VPRE_Y;
			_mm_store_si128_emu(prandex, tempa2);

			const __m128i temp22 = VPRE_S;
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			acc = _mm_xor_si128_emu(add12, acc);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prand, tempb2);
			break;
		}
		VERUS_CASE8(8):
		{
			const __m128i temp1 = VPRE_Y;
			const __m128i temp2 = VPRE_B;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			acc = _mm_xor_si128_emu(add1, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = VPRE_X;
			_mm_store_si128_emu(prand, tempa2);

			const __m128i temp22 = VPRE_S;
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			acc = _mm_xor_si128_emu(clprod12, acc);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			acc = _mm_xor_si128_emu(clprod22, acc);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandex, tempb2);
			break;
		}
		VERUS_CASE8(0xc):
		{
			const __m128i temp1 = VPRE_X;
			const __m128i temp2 = VPRE_S;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);

			// cannot be zero here
			const int32_t divisor = (uint32_t)selector;

			acc = _mm_xor_si128_emu(add1, acc);

			const int64_t dividend = _mm_cvtsi128_si64_emu(acc);
                        asm(".global __use_realtime_division\n");
			const __m128i modulo = _mm_cvtsi32_si128_emu(VERUS_ABL_MOD(dividend, divisor));
			acc = _mm_xor_si128_emu(modulo, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			if (SEL & 32) {
				/* SEL bit 5 (32): the 50/50 'dividend & 1' choice without a branch. Both arms are computed;
				 * the two stores go to the same addresses in the same order as the arm taken, so the
				 * prand == prandex corner stays identical:
				 *   odd:  *prandex = tempa2; acc ^= clmul(Y ^ Q) ^ clmul(Q); *prand = mulhrs(acc, Y) ^ Y
				 *   even: *prand = Y;        *prandex = tempa2;              acc ^= Q */
				const uint64_t odd = (uint64_t)dividend & 1;
				const __m128i Y = VPRE_Y;
				const __m128i Q = VPRE_B;
				const uint64x2_t m = vdupq_n_u64(0 - odd);
				const __m128i v = _mm_xor_si128_emu(Y, Q);
				const __m128i fodd = _mm_xor_si128_emu(_mm_clmulepi64_si128_emu(v, v, 0x10), _mm_clmulepi64_si128_emu(Q, Q, 0x10));
				acc = _mm_xor_si128_emu(acc, vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(fodd), vreinterpretq_u64_s64(Q))));
				const __m128i lastodd = _mm_xor_si128_emu(_mm_mulhrs_epi16_emu(acc, Y), Y);
				__m128i *p1 = odd ? prandex : prand;
				__m128i *p2 = odd ? prand : prandex;
				_mm_store_si128_emu(p1, vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(tempa2), vreinterpretq_u64_s64(Y))));
				_mm_store_si128_emu(p2, vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(lastodd), vreinterpretq_u64_s64(tempa2))));
			} else
			if (dividend & 1)
			{
				const __m128i temp12 = VPRE_Y;
				_mm_store_si128_emu(prandex, tempa2);

				const __m128i temp22 = VPRE_B;
				const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
				const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
				acc = _mm_xor_si128_emu(clprod12, acc);
				const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
				acc = _mm_xor_si128_emu(clprod22, acc);

				const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, temp12);
				const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
				_mm_store_si128_emu(prand, tempb2);
			}
			else
			{
				*prand = VPRE_Y;
				_mm_store_si128_emu(prandex, tempa2);
				const __m128i tempb4 = VPRE_B;
				acc = _mm_xor_si128_emu(tempb4, acc);
			}
			break;
		}
		VERUS_CASE8(0x10):
		{
			// a few AES operations
			const __m128i *rc = prand;
			__m128i tmp;

			__m128i temp1 = VPRE_S;
			__m128i temp2 = VPRE_B;

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			acc = _mm_xor_si128_emu(temp1, acc);
			acc = _mm_xor_si128_emu(temp2, acc);

			const __m128i tempa1 = VPRE_X;
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);

			*prand = VPRE_Y;
			*prandex = _mm_xor_si128_emu(tempa1, tempa2);
			break;
		}
		case VERUS_CASEL(0x14):
		{
			// we'll just call this one the monkins loop, inspired by Chris
			const __m128i *buftmp = pbsf;
			__m128i tmp; // used by MIX2

			int64_t rounds = selector >> 61; // loop randomly between 1 and 8 times
			__m128i *rc = prand;
			uint64_t aesround = 0;
			__m128i onekey, temp1a, temp1b, temp2a, temp2b;
if (SEL & 4) {
			/* variant x2sel3: case 0x14 without any branch. The loop runs (selector >> 61) + 1 steps; every
			 * step's contribution depends only on the key, the buffer and the selector, never on acc, so all
			 * 8 possible steps are computed (independent, so they run in parallel on an out-of-order core) and
			 * masks keep exactly the steps and arms the original loop would execute. Same result. */
			const int64_t r0 = rounds;
			__m128i sum = _mm_setzero_si128();
#pragma clang loop unroll(full)
			for (int j = 0; j < 8; j++)
			{
				const int64_t rj = r0 - j;                       /* the original 'rounds' at this step */
				const uint64_t active = (rj >= 0) ? 1 : 0;
				const int64_t rs = rj & 7;                       /* any valid shift for inactive steps */
				const uint64_t bit = VERUS_ABL_INNER(selector, rs) ? 1 : 0;
				const __m128i key_j = _mm_load_si128_emu(prand + j);
				const __m128i tc = _mm_load_si128_emu(rs & 1 ? pbuf : pbsf);
				const __m128i addc = _mm_xor_si128_emu(key_j, tc);
				const __m128i clprodc = _mm_clmulepi64_si128_emu(addc, addc, 0x10);
				__m128i ka = key_j;
				__m128i ta = _mm_load_si128_emu(rs & 1 ? pbsf : pbuf);
				{
					const __m128i *rc = prand + j + 1;           /* the original rc after its ++ */
					const uint64_t roundidx = aesround << 2;
					AES2(ka, ta, roundidx);
				}
				MIX2_EMU(ka, ta);
				const __m128i aesv = _mm_xor_si128_emu(ka, ta);
				const uint64x2_t mb = vdupq_n_u64(0 - bit);
				const __m128i contrib = vreinterpretq_s64_u64(vbslq_u64(mb, vreinterpretq_u64_s64(clprodc), vreinterpretq_u64_s64(aesv)));
				sum = _mm_xor_si128_emu(sum, vreinterpretq_s64_u64(vandq_u64(vreinterpretq_u64_s64(contrib), vdupq_n_u64(0 - active))));
				aesround += active & (1 - bit);
			}
			acc = _mm_xor_si128_emu(acc, sum);
			rounds = -1;
			} else {
#pragma clang loop unroll(full)
                        //for ( int64_t count = 1; count <= 8; count++ )
                        for ( uint64_t count = 8; count--;  )
                        {
                                if ( rounds >= 0 )
                                {
                                                onekey = _mm_load_si128_emu(rc++);
                                                //printf("selector %" PRIu64 "\n", selector);

if (SEL & 1) {
                                                /* variant x2sel: both arms are computed and the result is selected
                                                 * without a branch. Neither arm depends on acc until the final XOR, so
                                                 * an out-of-order core runs them ahead; this removes a 50/50 branch
                                                 * per iteration. Same result as the if/else below. */
                                                {
                                                        const uint64_t bit = VERUS_ABL_INNER(selector, rounds) ? 1 : 0;
                                                        const __m128i tc = _mm_load_si128_emu(rounds & 1 ? pbuf : pbsf);
                                                        const __m128i addc = _mm_xor_si128_emu(onekey, tc);
                                                        const __m128i clprodc = _mm_clmulepi64_si128_emu(addc, addc, 0x10);
                                                        __m128i ka = onekey;
                                                        __m128i ta = _mm_load_si128_emu(rounds & 1 ? pbsf : pbuf);
                                                        const uint64_t roundidx = aesround << 2;
                                                        AES2(ka, ta, roundidx);
                                                        MIX2_EMU(ka, ta);
                                                        const __m128i aesv = _mm_xor_si128_emu(ka, ta);
                                                        const uint64x2_t m = vdupq_n_u64(0 - bit);
                                                        acc = _mm_xor_si128_emu(acc, vreinterpretq_s64_u64(vbslq_u64(m,
                                                                vreinterpretq_u64_s64(clprodc), vreinterpretq_u64_s64(aesv))));
                                                        aesround += 1 - bit;
                                                }
} else {
                                                if (VERUS_ABL_INNER(selector, rounds))
                                                {
                                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : pbsf);  //rounds is odd
                                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
                                                        const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                                        acc = _mm_xor_si128_emu(clprod1, acc);
                                                }
                                                else
                                                {
                                                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbsf : pbuf);  //rounds is odd
                                                        const uint64_t roundidx = aesround++ << 2;
                                                        AES2(onekey, temp2, roundidx);

                                                        MIX2_EMU(onekey, temp2);

                                                        acc ^= onekey ^ temp2;
                                                }
}
                                rounds--;
                                }
                        }
			}


			const __m128i tempa1 = VPRE_X;
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);
			*prand = VPRE_Y;
			*prandex = _mm_xor_si128_emu(tempa1, tempa2);

			break;
		}
		case VERUS_CASEL(0x18):
   {   
             const __m128i *buftmp = pbsf;
                __m128i tmp; // used by MIX2

                int64_t rounds = selector >> 61; // loop randomly between 1 and 8 times
                __m128i *rc = prand;
                __m128i onekey;

//                do
//                {
//                    if (selector & (((uint64_t)0x10000000) << rounds))
//                    {
//                        onekey = _mm_load_si128_emu(rc++);
//                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : buftmp);
//                        onekey = _mm_xor_si128_emu(onekey, temp2);
//                        // cannot be zero here, may be negative
//                        const int32_t divisor = (uint32_t)selector;
//                        const int64_t dividend = _mm_cvtsi128_si64_emu(onekey);
//                        const __m128i modulo = _mm_cvtsi32_si128_emu(dividend % divisor);
//                        acc = _mm_xor_si128_emu(modulo, acc);
//                    }
//                    else
//                    {
//                        onekey = _mm_load_si128_emu(rc++);
//                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? buftmp : pbuf);
//                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
//                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
//                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(acc, onekey);
//                        acc = _mm_xor_si128_emu(clprod2, acc);
//                    }
//                } while (rounds--);
  
#pragma clang loop unroll(full)
                for ( uint64_t count = 8; count--;  )
                {
                        if ( rounds >= 0 )
                        {
                                    onekey = _mm_load_si128_emu(rc++);
if (SEL & 2) {
                                    /* variant x2sel2: both arms computed, result selected without a branch.
                                     * The divide arm does not depend on acc, so it runs ahead on an
                                     * out-of-order core; the price is a divide on every iteration. */
                                    {
                                        const uint64_t bit = VERUS_ABL_INNER(selector, rounds) ? 1 : 0;
                                        const __m128i td = _mm_load_si128_emu(rounds & 1 ? pbuf : pbsf );
                                        const __m128i okd = _mm_xor_si128_emu(onekey, td);
                                        const int32_t divisor = (uint32_t)selector;
                                        const int64_t dividend = _mm_cvtsi128_si64(okd);
                                        asm(".global __use_realtime_division\n");
                                        const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor));
                                        const __m128i accd = _mm_xor_si128_emu(modulo, acc);
                                        const __m128i tcl = _mm_load_si128_emu(rounds & 1 ? pbsf : pbuf);
                                        const __m128i addc = _mm_xor_si128_emu(onekey, tcl);
                                        const __m128i okc = _mm_clmulepi64_si128_emu(addc, addc, 0x10);
                                        const __m128i accc = _mm_xor_si128_emu(_mm_mulhrs_epi16_emu(acc, okc), acc);
                                        const uint64x2_t m = vdupq_n_u64(0 - bit);
                                        acc = vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(accd), vreinterpretq_u64_s64(accc)));
                                        onekey = vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(okd), vreinterpretq_u64_s64(okc)));
                                    }
} else {
                                    if (VERUS_ABL_INNER(selector, rounds))
                                    {
                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbuf : pbsf );
                                        onekey = _mm_xor_si128_emu(onekey, temp2);
                                        // cannot be zero here, may be negative
  		                        const int32_t divisor = (uint32_t)selector;
                                        const int64_t dividend = _mm_cvtsi128_si64(onekey);
                                        asm(".global __use_realtime_division\n");
                                        const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor));
                                        acc = _mm_xor_si128_emu(modulo, acc);
                                    }
                                    else
                                    {
                                        const __m128i temp4 = _mm_load_si128_emu(rounds & 1 ? pbsf : pbuf);
                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp4);
                                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(acc, onekey);
                                        acc = _mm_xor_si128_emu(clprod2, acc);
                                    }
}
                                    rounds--;
                        }
                }


                *prand = _mm_xor_si128_emu(VPRE_Y, acc);
                _mm_store_si128_emu(prandex, onekey);
                break;
            }
		if (VERUS_FOLD) {
			if (0) {
				/* entry stubs; the empty asm keeps each stub a block of its own, so its two settings are not
				 * moved in front of the case jump */
#define VERUS_S14(r) case VERUS_CASEX(0x14, r): f_aes = 0; f_end = prand + (r); __asm__ volatile(""); goto verus_f14_##r;
				VERUS_S14(7) VERUS_S14(6) VERUS_S14(5) VERUS_S14(4) VERUS_S14(3) VERUS_S14(2) VERUS_S14(1) VERUS_S14(0)
#undef VERUS_S14
#define VERUS_S18(r) case VERUS_CASEX(0x18, r): f_end = prand + (r); __asm__ volatile(""); goto verus_f18_##r;
				VERUS_S18(7) VERUS_S18(6) VERUS_S18(5) VERUS_S18(4) VERUS_S18(3) VERUS_S18(2) VERUS_S18(1) VERUS_S18(0)
#undef VERUS_S18
			}
#define VERUS_F14(r) verus_f14_##r: { \
			__m128i onekey = _mm_load_si128_emu(f_end - (r)); \
			const __m128i *rc = f_end - (r) + 1; __m128i tmp; \
			if (SEL & 1) { \
				const uint64_t bit = VERUS_ABL_INNER(selector, r) ? 1 : 0; \
				const __m128i tc = _mm_load_si128_emu((r) & 1 ? pbuf : pbsf); \
				const __m128i addc = _mm_xor_si128_emu(onekey, tc); \
				const __m128i clprodc = _mm_clmulepi64_si128_emu(addc, addc, 0x10); \
				__m128i ta = _mm_load_si128_emu((r) & 1 ? pbsf : pbuf); \
				const uint64_t roundidx = f_aes << 2; \
				AES2(onekey, ta, roundidx); \
				MIX2_EMU(onekey, ta); \
				const __m128i aesv = _mm_xor_si128_emu(onekey, ta); \
				const uint64x2_t m = vdupq_n_u64(0 - bit); \
				acc = _mm_xor_si128_emu(acc, vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(clprodc), vreinterpretq_u64_s64(aesv)))); \
				f_aes += 1 - bit; \
			} else if (VERUS_ABL_INNER(selector, r)) { \
				const __m128i temp2 = _mm_load_si128_emu((r) & 1 ? pbuf : pbsf); \
				const __m128i add1 = _mm_xor_si128_emu(onekey, temp2); \
				const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10); \
				acc = _mm_xor_si128_emu(clprod1, acc); \
			} else { \
				__m128i temp2 = _mm_load_si128_emu((r) & 1 ? pbsf : pbuf); \
				const uint64_t roundidx = f_aes++ << 2; \
				AES2(onekey, temp2, roundidx); \
				MIX2_EMU(onekey, temp2); \
				acc = _mm_xor_si128_emu(acc, _mm_xor_si128_emu(onekey, temp2)); \
			} \
			(void)rc; (void)tmp; }
			VERUS_F14(7) VERUS_F14(6) VERUS_F14(5) VERUS_F14(4) VERUS_F14(3) VERUS_F14(2) VERUS_F14(1) VERUS_F14(0)
#undef VERUS_F14
			{
				const __m128i tempa1 = VPRE_X;
				const __m128i tempa2 = _mm_mulhrs_epi16_emu(acc, tempa1);
				*prand = VPRE_Y;
				*prandex = _mm_xor_si128_emu(tempa1, tempa2);
			}
			break;
#define VERUS_F18(r) verus_f18_##r: { \
			__m128i onekey = _mm_load_si128_emu(f_end - (r)); \
			if (SEL & 2) { \
				const uint64_t bit = VERUS_ABL_INNER(selector, r) ? 1 : 0; \
				const __m128i td = _mm_load_si128_emu((r) & 1 ? pbuf : pbsf); \
				const __m128i okd = _mm_xor_si128_emu(onekey, td); \
				const int32_t divisor = (uint32_t)selector; \
				const int64_t dividend = _mm_cvtsi128_si64(okd); \
				const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor)); \
				const __m128i accd = _mm_xor_si128_emu(modulo, acc); \
				const __m128i tcl = _mm_load_si128_emu((r) & 1 ? pbsf : pbuf); \
				const __m128i addc = _mm_xor_si128_emu(onekey, tcl); \
				const __m128i okc = _mm_clmulepi64_si128_emu(addc, addc, 0x10); \
				const __m128i accc = _mm_xor_si128_emu(_mm_mulhrs_epi16_emu(acc, okc), acc); \
				const uint64x2_t m = vdupq_n_u64(0 - bit); \
				acc = vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(accd), vreinterpretq_u64_s64(accc))); \
				f_ok = vreinterpretq_s64_u64(vbslq_u64(m, vreinterpretq_u64_s64(okd), vreinterpretq_u64_s64(okc))); \
			} else if (VERUS_ABL_INNER(selector, r)) { \
				const __m128i temp2 = _mm_load_si128_emu((r) & 1 ? pbuf : pbsf); \
				onekey = _mm_xor_si128_emu(onekey, temp2); \
				const int32_t divisor = (uint32_t)selector; \
				const int64_t dividend = _mm_cvtsi128_si64(onekey); \
				const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor)); \
				acc = _mm_xor_si128_emu(modulo, acc); \
				f_ok = onekey; \
			} else { \
				const __m128i temp4 = _mm_load_si128_emu((r) & 1 ? pbsf : pbuf); \
				const __m128i add1 = _mm_xor_si128_emu(onekey, temp4); \
				onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10); \
				const __m128i clprod2 = _mm_mulhrs_epi16_emu(acc, onekey); \
				acc = _mm_xor_si128_emu(clprod2, acc); \
				f_ok = onekey; \
			} }
			VERUS_F18(7) VERUS_F18(6) VERUS_F18(5) VERUS_F18(4) VERUS_F18(3) VERUS_F18(2) VERUS_F18(1) VERUS_F18(0)
#undef VERUS_F18
			*prand = _mm_xor_si128_emu(VPRE_Y, acc);
			_mm_store_si128_emu(prandex, f_ok);
			break;
		}
		case VERUS_CASED(0): case VERUS_CASED(1): case VERUS_CASED(2): case VERUS_CASED(3):
		case VERUS_CASED(4): case VERUS_CASED(5): case VERUS_CASED(6): case VERUS_CASED(7):
		verus_case_1c:
		{
			const __m128i temp1 = VPRE_B;
			const __m128i temp2 = VPRE_Y;
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			acc = _mm_xor_si128_emu(clprod1, acc);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(acc, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = VPRE_X;
			_mm_store_si128_emu(prand, tempa2);

			acc = _mm_xor_si128_emu(tempa3, acc);
			const __m128i temp4 = VPRE_S;
			acc = _mm_xor_si128(temp4, acc);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(acc, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandex, tempb2);
			break;
		}
		default:
			/* lean + fold: the index comes from inline asm, so tell the compiler that every value has a
			 * label (no range check in front of the table jump) */
			if (VERUS_FOLD && (SEL & 2048) && FIXC < 0) __builtin_unreachable();
			goto verus_case_1c;
		}

   
	}

#undef VERUS_FOLD
#undef VERUS_CASE
#undef VERUS_CASEX
#undef VERUS_CASEL
#undef VERUS_CASE8
#undef VERUS_CASED
#undef VPRE_X
#undef VPRE_Y
#undef VPRE_B
#undef VPRE_S
/* N independent nonces in lockstep (N = 2..4), each lane with its own key. Round code is the same as the
 * single-nonce loop; only the order of execution differs. */
#if defined(__GNUC__)
/* SEL bit 13 (8192), "goto": the case jump of each lane is ONE computed goto through a table of label addresses
 * (ldr + br: no adr/add, one step less between the selector and the jump than the compiler's switch table).
 * The whole round set-up (journal store, prand, prandex, pbuf, pbsf) stays in front of the jump. Needs fold
 * (1024), lean (2048) and the pristine restore (128).
 * SEL bits 14-15 (16384, 32768) = A, "arms": the arm choices of the LAST A rounds of cases 0x14 / 0x18 (rounds
 * 0 .. A-1 test the fixed selector bits 28 .. 28+A-1) are part of the jump index too. The case jump mispredicts
 * anyway; with A arms known at the jump, those 50/50 arm branches are gone. The round chain of the two cases
 * exists 2^A times (one copy per arm combination; rounds >= A keep their branch), the tables hold 2^A x 64
 * addresses per lane.
 * One jump site per lane: the empty asm goto in front of 'goto vgb_disp' keeps the compiler from copying the
 * jump block to the end of every lane-0 case. SEL bit 16 (65536), "dup", leaves that copying to the compiler
 * (lane 0's cases then end with their own jump for lane 1, no branch back to a shared block).
 * Cases 0x14 / 0x18 here: prand itself walks over the key words of the rounds (round r of an entry at R reads
 * prand[R - r], as the original rc++ does); the last step recomputes the original prand from the selector. */
#if defined(__aarch64__)
#define VERUS_GT_LOAD(tgt, row, fi) __asm__("ldr %0, [%1, %2, lsl #3]" : "=r"(tgt) : "r"(row), "r"(fi))
#else
#define VERUS_GT_LOAD(tgt, row, fi) tgt = (row)[fi]
#endif
/* The jump block of a lane: 11 instructions (13 with arms); between the selector and the jump: fmov, lsr,
 * bfxil, ldr, br. The empty asm statements pin values to registers at this point: the accumulator (so this
 * lane's set-up is not hoisted into the other lane's block), the prandex pointer (otherwise every case starts
 * with a shift of the index). The table load is written out because the compiler splits it into add + ldr. */
#define VERUS_GT_DISP(TAB, l, AM) { \
	__asm__("" : "+w"(ac[l])); \
	selv = (uint64_t)_mm_cvtsi128_si64_emu(ac[l]); \
	*(verus_u64_alias *)((char *)frl[l] + i8) = selv; \
	prand = rsl[l] + ((selv >> 5) & keyMask); prandex = rsl[l] + ((selv >> 32) & keyMask); \
	__asm__("" : "+r"(prandex)); \
	pbi = selv & 3; psi = pbi ^ 1; \
	const void *const *row = (AM) ? (TAB) + (((selv >> 28) & (AM)) << 6) : (TAB); \
	const uint64_t fi = verus_fold_index(selv); const void *tgt; \
	VERUS_GT_LOAD(tgt, row, fi); \
	goto *tgt; }
#define VERUS_GT_SIMPLE(P, l, k, AFTER) P##c##k: \
	verus_round_port2_2<SEL, k>(ac[l], 0, rsl[l], pcb[l], keyMask, nullptr, nullptr, nullptr, nullptr, selv, prand, prandex, pcb[l] + pbi, pcb[l] + psi); AFTER
#define VERUS_GT_BIT(A, a, r) ((r) < (A) ? ((((a) >> (r)) & 1) != 0) : (VERUS_ABL_INNER(selv, r) != 0))
#define VERUS_GT_R14(P, l, A, a, r) P##f14_##a##_##r: { \
	__m128i onekey = _mm_load_si128_emu(prand); \
	const __m128i *rc = ++prand; __m128i tmp; \
	if (VERUS_GT_BIT(A, a, r)) { \
		const __m128i temp2 = _mm_load_si128_emu((r) & 1 ? pcb[l] + pbi : pcb[l] + psi); \
		const __m128i add1 = _mm_xor_si128_emu(onekey, temp2); \
		const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10); \
		ac[l] = _mm_xor_si128_emu(clprod1, ac[l]); \
	} else { \
		__m128i temp2 = _mm_load_si128_emu((r) & 1 ? pcb[l] + psi : pcb[l] + pbi); \
		const uint64_t roundidx = f_aes++ << 2; \
		AES2(onekey, temp2, roundidx); \
		MIX2_EMU(onekey, temp2); \
		ac[l] = _mm_xor_si128_emu(ac[l], _mm_xor_si128_emu(onekey, temp2)); \
	} (void)rc; (void)tmp; }
#define VERUS_GT_R18(P, l, A, a, r) P##f18_##a##_##r: { \
	__m128i onekey = _mm_load_si128_emu(prand); prand++; \
	if (VERUS_GT_BIT(A, a, r)) { \
		const __m128i temp2 = _mm_load_si128_emu((r) & 1 ? pcb[l] + pbi : pcb[l] + psi); \
		onekey = _mm_xor_si128_emu(onekey, temp2); \
		const int32_t divisor = (uint32_t)selv; \
		const int64_t dividend = _mm_cvtsi128_si64(onekey); \
		const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor)); \
		ac[l] = _mm_xor_si128_emu(modulo, ac[l]); \
	} else { \
		const __m128i temp4 = _mm_load_si128_emu((r) & 1 ? pcb[l] + psi : pcb[l] + pbi); \
		const __m128i add1 = _mm_xor_si128_emu(onekey, temp4); \
		onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10); \
		const __m128i clprod2 = _mm_mulhrs_epi16_emu(ac[l], onekey); \
		ac[l] = _mm_xor_si128_emu(clprod2, ac[l]); \
	} f_ok = onekey; }
#define VERUS_GT_COPY(P, l, A, a, AFTER) \
	VERUS_GT_R14(P, l, A, a, 7) VERUS_GT_R14(P, l, A, a, 6) VERUS_GT_R14(P, l, A, a, 5) VERUS_GT_R14(P, l, A, a, 4) \
	VERUS_GT_R14(P, l, A, a, 3) VERUS_GT_R14(P, l, A, a, 2) VERUS_GT_R14(P, l, A, a, 1) VERUS_GT_R14(P, l, A, a, 0) \
	{ __m128i *p0 = rsl[l] + ((selv >> 5) & keyMask); \
	  const __m128i tempa1 = _mm_load_si128_emu(p0); \
	  const __m128i tempa2 = _mm_mulhrs_epi16_emu(ac[l], tempa1); \
	  *p0 = _mm_load_si128_emu(prandex); \
	  *prandex = _mm_xor_si128_emu(tempa1, tempa2); \
	  f_aes = 0; } AFTER \
	VERUS_GT_R18(P, l, A, a, 7) VERUS_GT_R18(P, l, A, a, 6) VERUS_GT_R18(P, l, A, a, 5) VERUS_GT_R18(P, l, A, a, 4) \
	VERUS_GT_R18(P, l, A, a, 3) VERUS_GT_R18(P, l, A, a, 2) VERUS_GT_R18(P, l, A, a, 1) VERUS_GT_R18(P, l, A, a, 0) \
	{ __m128i *p0 = rsl[l] + ((selv >> 5) & keyMask); \
	  *p0 = _mm_xor_si128_emu(_mm_load_si128_emu(prandex), ac[l]); \
	  _mm_store_si128_emu(prandex, f_ok); } AFTER
#define VERUS_GT_COPIES_0(P, l, A, AFTER) VERUS_GT_COPY(P, l, A, 0, AFTER)
#define VERUS_GT_COPIES_1(P, l, A, AFTER) VERUS_GT_COPY(P, l, A, 0, AFTER) VERUS_GT_COPY(P, l, A, 1, AFTER)
#define VERUS_GT_COPIES_2(P, l, A, AFTER) VERUS_GT_COPY(P, l, A, 0, AFTER) VERUS_GT_COPY(P, l, A, 1, AFTER) \
	VERUS_GT_COPY(P, l, A, 2, AFTER) VERUS_GT_COPY(P, l, A, 3, AFTER)
#define VERUS_GT_LANE(P, l, A, AFTER) \
	VERUS_GT_SIMPLE(P, l, 0, AFTER) VERUS_GT_SIMPLE(P, l, 1, AFTER) VERUS_GT_SIMPLE(P, l, 2, AFTER) \
	VERUS_GT_SIMPLE(P, l, 3, AFTER) VERUS_GT_SIMPLE(P, l, 4, AFTER) VERUS_GT_SIMPLE(P, l, 7, AFTER) \
	VERUS_GT_COPIES_##A(P, l, A, AFTER)
/* table row r: jump indices r*8 .. r*8+7 = the eight cases with (selector >> 61) == r */
#define VERUS_GT_ROW(P, a, r) &&P##c0, &&P##c1, &&P##c2, &&P##c3, &&P##c4, &&P##f14_##a##_##r, &&P##f18_##a##_##r, &&P##c7
#define VERUS_GT_TAB(P, a) { VERUS_GT_ROW(P, a, 0), VERUS_GT_ROW(P, a, 1), VERUS_GT_ROW(P, a, 2), VERUS_GT_ROW(P, a, 3), \
	VERUS_GT_ROW(P, a, 4), VERUS_GT_ROW(P, a, 5), VERUS_GT_ROW(P, a, 6), VERUS_GT_ROW(P, a, 7) }
#define VERUS_GT_TABS_0(P) VERUS_GT_TAB(P, 0)
#define VERUS_GT_TABS_1(P) VERUS_GT_TAB(P, 0), VERUS_GT_TAB(P, 1)
#define VERUS_GT_TABS_2(P) VERUS_GT_TAB(P, 0), VERUS_GT_TAB(P, 1), VERUS_GT_TAB(P, 2), VERUS_GT_TAB(P, 3)
#define VERUS_GOTO_FUNC(NAME, A) \
template<int N, int SEL> \
static __attribute__((noinline)) void NAME(__m128i *acc, __m128i *const *rs, const __m128i (*pc)[4], uint16_t *const *fr, uint64_t keyMask) \
{ \
	static const void *const tab_a[1 << (A)][64] = { VERUS_GT_TABS_##A(vga_) }; \
	static const void *const tab_b[1 << (A)][64] = { VERUS_GT_TABS_##A(vgb_) }; \
	uint64_t i8 = 0, selv = 0, f_aes = 0, pbi = 0, psi = 0;   /* i8: round number x 8 (journal offset) */ \
	__m128i *prand = nullptr, *prandex = nullptr; \
	__m128i ac[2] = { acc[0], acc[N - 1] }; \
	__m128i f_ok = ac[0]; \
	__m128i *rsl[2] = { rs[0], rs[N - 1] }; \
	uint16_t *frl[2] = { fr[0], fr[N - 1] }; \
	const __m128i *pcb[2] = { pc[0], pc[N - 1] }; \
	__asm__("" : "+r"(pcb[0])); __asm__("" : "+r"(pcb[1])); \
	const void *const *ta = &tab_a[0][0]; const void *const *tb = &tab_b[0][0];   /* table addresses in registers */ \
	__asm__("" : "+r"(ta)); __asm__("" : "+r"(tb)); \
	goto vga_disp; \
	vga_disp: VERUS_GT_DISP(ta, 0, (1 << (A)) - 1) \
	vgb_disp: VERUS_GT_DISP(tb, N - 1, (1 << (A)) - 1) \
	VERUS_GT_LANE(vga_, 0, A, { if (N == 2) { if (!(SEL & 65536)) __asm__ goto("" : : : : vgb_disp); goto vgb_disp; } if ((i8 += 8) == 256) goto vg_done; goto vga_disp; }) \
	VERUS_GT_LANE(vgb_, N - 1, A, { if ((i8 += 8) == 256) goto vg_done; goto vga_disp; }) \
	vg_done: acc[0] = ac[0]; if (N == 2) acc[N - 1] = ac[N - 1]; \
}
VERUS_GOTO_FUNC(verus_goto_a0, 0)
VERUS_GOTO_FUNC(verus_goto_a1, 1)
VERUS_GOTO_FUNC(verus_goto_a2, 2)
/* only the (N, SEL) pairs that ask for it instantiate a goto function (A = -1: not this variant) */
template<int N, int SEL, int A> struct verus_goto_sel {
	FORCE_INLINE void run(__m128i *, __m128i *const *, const __m128i (*)[4], uint16_t *const *, uint64_t) {} };
template<int N, int SEL> struct verus_goto_sel<N, SEL, 0> {
	FORCE_INLINE void run(__m128i *acc, __m128i *const *rs, const __m128i (*pc)[4], uint16_t *const *fr, uint64_t keyMask) { verus_goto_a0<N, SEL>(acc, rs, pc, fr, keyMask); } };
template<int N, int SEL> struct verus_goto_sel<N, SEL, 1> {
	FORCE_INLINE void run(__m128i *acc, __m128i *const *rs, const __m128i (*pc)[4], uint16_t *const *fr, uint64_t keyMask) { verus_goto_a1<N, SEL>(acc, rs, pc, fr, keyMask); } };
template<int N, int SEL> struct verus_goto_sel<N, SEL, 2> {
	FORCE_INLINE void run(__m128i *acc, __m128i *const *rs, const __m128i (*pc)[4], uint16_t *const *fr, uint64_t keyMask) { verus_goto_a2<N, SEL>(acc, rs, pc, fr, keyMask); } };
#endif


template<int N, int SEL>
void verusclhash_port2_2_xN(void **random, const unsigned char **buf, uint64_t keyMask,
		uint16_t **fixrand_in, uint16_t **fixrandex_in, __m128i **g_prand_in, __m128i **g_prandex_in, uint64_t *out)
{
	/* Copy the per-lane pointers into locals first: with -fno-strict-aliasing the compiler would otherwise
	 * reload them from memory after every store through them. After full unrolling these become registers. */
	__m128i *rs[N];
	uint16_t * __restrict fr[N], * __restrict fre[N];
	__m128i *gp[N], *gpx[N];
	__m128i pc[N][4];
	__m128i acc[N];
#pragma clang loop unroll(full)
	for (int l = 0; l < N; l++) {
		const __m128i *a = (const __m128i *)buf[l];
		rs[l] = (__m128i *)random[l];
		fr[l] = fixrand_in[l]; fre[l] = fixrandex_in[l]; gp[l] = g_prand_in[l]; gpx[l] = g_prandex_in[l];
		pc[l][0] = _mm_xor_si128(a[0], a[2]); pc[l][1] = _mm_xor_si128(a[1], a[3]); pc[l][2] = a[2]; pc[l][3] = a[3];
		acc[l] = _mm_load_si128_emu(rs[l] + (keyMask + 2));
	}
#if defined(__GNUC__)
	if ((N == 1 || N == 2) && (SEL & 8192)) {
		verus_goto_sel<N, SEL, ((N == 1 || N == 2) && (SEL & 8192)) ? ((SEL >> 14) & 3) : -1>::run(acc, rs, pc, (uint16_t *const *)fr, keyMask);
	} else
	if ((N == 1 || N == 2) && (SEL & 4096)) {
		/* SEL bit 12 (4096), "threaded": needs fold (1024). Every case body ends with its own copy of the
		 * next lane's case jump (computed goto through a table of label addresses: ldr + br, no adr/add,
		 * no shared jump block to branch back to). Bodies are specialised per fold index; in front of the
		 * jump there is only the index (fmov, lsr, bfxil), the rest of the round set-up runs after it. */
#define VERUS_TH_NEXT(tab, l) { selv = (uint64_t)_mm_cvtsi128_si64_emu(acc[l]); goto *tab[verus_fold_index(selv)]; }
#define VERUS_TH_BODY(P, l, t, AFTER) P##t: verus_round_port2_2<SEL, t>(acc[l], i, rs[l], pcb[l], keyMask, fr[l], fre[l], gp[l], gpx[l], selv); AFTER
#define VERUS_TH_LANE(P, l, AFTER) \
		VERUS_TH_BODY(P, l, 0, AFTER) VERUS_TH_BODY(P, l, 1, AFTER) VERUS_TH_BODY(P, l, 2, AFTER) VERUS_TH_BODY(P, l, 3, AFTER) \
		VERUS_TH_BODY(P, l, 4, AFTER) VERUS_TH_BODY(P, l, 7, AFTER) \
		VERUS_TH_BODY(P, l, 5, AFTER) VERUS_TH_BODY(P, l, 13, AFTER) VERUS_TH_BODY(P, l, 21, AFTER) VERUS_TH_BODY(P, l, 29, AFTER) \
		VERUS_TH_BODY(P, l, 37, AFTER) VERUS_TH_BODY(P, l, 45, AFTER) VERUS_TH_BODY(P, l, 53, AFTER) VERUS_TH_BODY(P, l, 61, AFTER) \
		VERUS_TH_BODY(P, l, 6, AFTER) VERUS_TH_BODY(P, l, 14, AFTER) VERUS_TH_BODY(P, l, 22, AFTER) VERUS_TH_BODY(P, l, 30, AFTER) \
		VERUS_TH_BODY(P, l, 38, AFTER) VERUS_TH_BODY(P, l, 46, AFTER) VERUS_TH_BODY(P, l, 54, AFTER) VERUS_TH_BODY(P, l, 62, AFTER)
		static const void *const tab_a[64] = {
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_5,  &&verus_ta_6,  &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_13, &&verus_ta_14, &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_21, &&verus_ta_22, &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_29, &&verus_ta_30, &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_37, &&verus_ta_38, &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_45, &&verus_ta_46, &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_53, &&verus_ta_54, &&verus_ta_7,
			&&verus_ta_0, &&verus_ta_1, &&verus_ta_2, &&verus_ta_3, &&verus_ta_4, &&verus_ta_61, &&verus_ta_62, &&verus_ta_7 };
		static const void *const tab_b[64] = {
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_5,  &&verus_tb_6,  &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_13, &&verus_tb_14, &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_21, &&verus_tb_22, &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_29, &&verus_tb_30, &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_37, &&verus_tb_38, &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_45, &&verus_tb_46, &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_53, &&verus_tb_54, &&verus_tb_7,
			&&verus_tb_0, &&verus_tb_1, &&verus_tb_2, &&verus_tb_3, &&verus_tb_4, &&verus_tb_61, &&verus_tb_62, &&verus_tb_7 };
		uint64_t i = 0, selv;
		/* the four buffer words of each lane live on the stack; keep their address in a register (sp cannot
		 * be the base of a scaled-index load, the compiler would copy it in every round) */
		const __m128i *pcb[N];
#pragma clang loop unroll(full)
		for (int l = 0; l < N; l++) { pcb[l] = pc[l]; __asm__("" : "+r"(pcb[l])); }
		VERUS_TH_NEXT(tab_a, 0)
		/* after a lane-0 body: with two lanes the other lane's jump, with one lane the next round */
#define VERUS_TH_AFTER_A { if (N == 2) VERUS_TH_NEXT(tab_b, N - 1) if (++i == 32) goto verus_th_done; VERUS_TH_NEXT(tab_a, 0) }
#define VERUS_TH_AFTER_B { if (++i == 32) goto verus_th_done; VERUS_TH_NEXT(tab_a, 0) }
		VERUS_TH_LANE(verus_ta_, 0, VERUS_TH_AFTER_A)
		VERUS_TH_LANE(verus_tb_, N - 1, VERUS_TH_AFTER_B)
	verus_th_done: ;
#undef VERUS_TH_NEXT
#undef VERUS_TH_BODY
#undef VERUS_TH_LANE
#undef VERUS_TH_AFTER_A
#undef VERUS_TH_AFTER_B
	} else
#endif
#if defined(__aarch64__)
	if ((N == 1 || N == 2) && (SEL & 64)) {
		/* SEL bit 6 (64): branch-table dispatch. A jump table needs a load of the table entry before the
		 * indirect jump can resolve, and that load sits on the path of every mispredict (~7 of 8 rounds).
		 * Here the jump goes to base + 4 * case, where each slot is a direct branch to that case's body
		 * (the case is a compile-time constant there, so each body is specialised as in the fused path). */
		constexpr int S = SEL & ~64;
		/* no declarations between the asm goto and its labels: clang <= 17 rejects jumps that cross any scope */
#define VERUS_BT_LANE(l, P) \
			asm goto("adr x16, 1f\n\tadd x16, x16, %0, lsl #2\n\tbr x16\n1:\n\tb %l1\n\tb %l2\n\tb %l3\n\tb %l4\n\tb %l5\n\tb %l6\n\tb %l7\n\tb %l8\n" \
				: : "r"((((uint64_t)_mm_cvtsi128_si64_emu(acc[l])) >> 2) & 7) : "x16" : P##0, P##1, P##2, P##3, P##4, P##5, P##6, P##7); \
			P##0: verus_round_port2_2<S, 0x00>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##1: verus_round_port2_2<S, 0x04>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##2: verus_round_port2_2<S, 0x08>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##3: verus_round_port2_2<S, 0x0c>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##4: verus_round_port2_2<S, 0x10>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##5: verus_round_port2_2<S, 0x14>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##6: verus_round_port2_2<S, 0x18>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); goto P##d; \
			P##7: verus_round_port2_2<S, 0x1c>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]); \
			P##d: ;
		uint64_t i = 0;
	verus_bt_loop:
		VERUS_BT_LANE(0, verus_bt_a)
		if (N == 2) { VERUS_BT_LANE(N - 1, verus_bt_b) }
		if (++i < 32) goto verus_bt_loop;
#undef VERUS_BT_LANE
	} else
#endif
	if (N == 2 && (SEL & 8)) {
		/* SEL bit 3: fused dispatch. One 64-way jump per round on the pair (case of lane 0, case of lane 1);
		 * every pair is a straight-line block with both case bodies (as primo-arm-miner's x2f path). */
#pragma clang loop unroll(disable)
		for (uint64_t i = 0; i < 32; i++) {
			const uint32_t fz = (uint32_t)(((_mm_cvtsi128_si64_emu(acc[0]) & 0x1c) << 1) | ((_mm_cvtsi128_si64_emu(acc[N - 1]) & 0x1c) >> 2));
#define VERUS_F64_CASE(I, J) case ((I) << 3) | (J): \
			verus_round_port2_2<SEL, (I) * 4>(acc[0], i, rs[0], pc[0], keyMask, fr[0], fre[0], gp[0], gpx[0]); \
			verus_round_port2_2<SEL, (J) * 4>(acc[N - 1], i, rs[N - 1], pc[N - 1], keyMask, fr[N - 1], fre[N - 1], gp[N - 1], gpx[N - 1]); \
			break;
#define VERUS_F64_ROW(I) VERUS_F64_CASE(I, 0) VERUS_F64_CASE(I, 1) VERUS_F64_CASE(I, 2) VERUS_F64_CASE(I, 3) \
			VERUS_F64_CASE(I, 4) VERUS_F64_CASE(I, 5) VERUS_F64_CASE(I, 6) VERUS_F64_CASE(I, 7)
			switch (fz) {
			VERUS_F64_ROW(0) VERUS_F64_ROW(1) VERUS_F64_ROW(2) VERUS_F64_ROW(3)
			VERUS_F64_ROW(4) VERUS_F64_ROW(5) VERUS_F64_ROW(6) VERUS_F64_ROW(7)
			}
#undef VERUS_F64_ROW
#undef VERUS_F64_CASE
		}
	} else
	for (uint64_t i = 0; i < 32; i++)
	{
#pragma clang loop unroll(full)
		for (int l = 0; l < N; l++)
			verus_round_port2_2<SEL>(acc[l], i, rs[l], pc[l], keyMask, fr[l], fre[l], gp[l], gpx[l]);
	}
#pragma clang loop unroll(full)
	for (int l = 0; l < N; l++) {
		acc[l] = _mm_xor_si128_emu(acc[l], _mm_cvtsi32_si128_emu(0x10000));
		out[l] = precompReduction64_port(acc[l]);
	}
}
template void verusclhash_port2_2_xN<2, 0>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 1>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 2>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 3>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 4>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 5>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 7>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 8>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 9>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 11>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 16>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 32>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 48>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 19>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 35>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 51>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 64>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 67>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 99>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 39>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 128>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 131>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 163>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 227>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 1152>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 1155>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 1187>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 3200>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 2176>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 7296>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 5248>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 11392>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 27776>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 44160>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 76928>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 93312>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 109696>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 512>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 515>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 547>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 640>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 643>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<2, 675>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
/* one lane (single-nonce cores through the same round code, VERUS_SEL1) */
template void verusclhash_port2_2_xN<1, 128>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 129>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 130>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 131>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 160>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 163>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 192>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 224>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 1152>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 1155>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 3200>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 2176>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 7296>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 5248>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 11392>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 27776>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 44160>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 640>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<1, 672>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<3, 0>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
template void verusclhash_port2_2_xN<4, 0>(void **, const unsigned char **, uint64_t, uint16_t **, uint16_t **, __m128i **, __m128i **, uint64_t *);
/* BEGIN GENERATED x2fuse (tools/gen_fuse.py) */
#ifdef VERUS_FUSE
/* variant x2fuse: two lanes with ONE 64-way jump per round on the pair (case of lane A, case of lane B).
 * GENERATED by gen_fuse.py from the case bodies of verus_round_port2_2 above; do not edit by hand.
 * - pairs where both cases are straight-line (0, 4, 8, 0x10, 0x1c) run both bodies in one block, so the
 *   compiler can interleave the two lanes (fills stall cycles on in-order cores);
 * - other pairs go through a stub: lane A's body, then an indirect jump to lane B's body whose target is
 *   predictable from branch history (the 64-way jump already chose it), so big cores take ~1 unpredictable
 *   jump per round pair instead of 2.
 * Lanes use separate keys, journals and buffers, hence the __restrict qualifiers. */
void verusclhash_port2_2_fuse2(__m128i * __restrict rsA, __m128i * __restrict rsB,
		const unsigned char *bufA, const unsigned char *bufB, uint64_t keyMask,
		uint16_t * __restrict fixrandA, uint16_t * __restrict fixrandexA, __m128i * __restrict g_prandA, __m128i * __restrict g_prandexA,
		uint16_t * __restrict fixrandB, uint16_t * __restrict fixrandexB, __m128i * __restrict g_prandB, __m128i * __restrict g_prandexB,
		uint64_t out[2])
{
	const __m128i *a = (const __m128i *)bufA;
	const __m128i *b = (const __m128i *)bufB;
	const __m128i pcA[4] = {_mm_xor_si128(a[0],a[2]), _mm_xor_si128(a[1],a[3]), a[2], a[3]};
	const __m128i pcB[4] = {_mm_xor_si128(b[0],b[2]), _mm_xor_si128(b[1],b[3]), b[2], b[3]};
	__m128i accA = _mm_load_si128_emu(rsA + (keyMask + 2));
	__m128i accB = _mm_load_si128_emu(rsB + (keyMask + 2));
	static void *const dispatch[64] = {
		&&F_0_0, &&F_0_1, &&F_0_2, &&P_0_3, &&F_0_4, &&P_0_5, &&P_0_6, &&F_0_7,
		&&F_1_0, &&F_1_1, &&F_1_2, &&P_1_3, &&F_1_4, &&P_1_5, &&P_1_6, &&F_1_7,
		&&F_2_0, &&F_2_1, &&F_2_2, &&P_2_3, &&F_2_4, &&P_2_5, &&P_2_6, &&F_2_7,
		&&P_3_0, &&P_3_1, &&P_3_2, &&P_3_3, &&P_3_4, &&P_3_5, &&P_3_6, &&P_3_7,
		&&F_4_0, &&F_4_1, &&F_4_2, &&P_4_3, &&F_4_4, &&P_4_5, &&P_4_6, &&F_4_7,
		&&P_5_0, &&P_5_1, &&P_5_2, &&P_5_3, &&P_5_4, &&P_5_5, &&P_5_6, &&P_5_7,
		&&P_6_0, &&P_6_1, &&P_6_2, &&P_6_3, &&P_6_4, &&P_6_5, &&P_6_6, &&P_6_7,
		&&F_7_0, &&F_7_1, &&F_7_2, &&P_7_3, &&F_7_4, &&P_7_5, &&P_7_6, &&F_7_7};
	uint64_t i = 0;
	__m128i *prandA, *prandexA, *prandB, *prandexB;
	__m128i const *pbufA, *pbsfA, *pbufB, *pbsfB;
	uint64_t selectorA, selectorB;
	void *nextB;
ROUND:
	{
		selectorA = _mm_cvtsi128_si64_emu(accA);
		selectorB = _mm_cvtsi128_si64_emu(accB);
		const uint64_t fudgeA = selectorA & 1 ? 1 : -1;
		const uint64_t fudgeB = selectorB & 1 ? 1 : -1;
		fixrandA[i]  = (uint16_t) ((selectorA >> 5) & keyMask);
		fixrandexA[i] = (uint16_t) ((selectorA >> 32) & keyMask);
		fixrandB[i]  = (uint16_t) ((selectorB >> 5) & keyMask);
		fixrandexB[i] = (uint16_t) ((selectorB >> 32) & keyMask);
		prandA = rsA + fixrandA[i]; prandexA = rsA + fixrandexA[i];
		prandB = rsB + fixrandB[i]; prandexB = rsB + fixrandexB[i];
		g_prandA[i] = *prandA; g_prandexA[i] = *prandexA;
		g_prandB[i] = *prandB; g_prandexB[i] = *prandexB;
		pbufA = pcA + (selectorA & 3); pbsfA = pbufA - fudgeA;
		pbufB = pcB + (selectorB & 3); pbsfB = pbufB - fudgeB;
	}
	goto *dispatch[((selectorA & 0x1c) << 1) | ((selectorB & 0x1c) >> 2)];

F_0_0:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			
			*prandexA  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			
			*prandexB  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto NEXT;
F_0_1:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			
			*prandexA  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accB = _mm_xor_si128_emu(clprod2, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexB);
			_mm_store_si128_emu(prandexB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accB = _mm_xor_si128_emu(add12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandB, tempb2);
			
	}
	goto NEXT;
F_0_2:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			
			*prandexA  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accB = _mm_xor_si128_emu(add1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accB = _mm_xor_si128_emu(clprod22, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexB, tempb2);
			
	}
	goto NEXT;
P_0_3: nextB = &&B_3; goto A_0;
F_0_4:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			
			*prandexA  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	{
			
			const __m128i *rc = prandB;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfB);
			__m128i temp2 = _mm_load_si128_emu(pbufB);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accB = _mm_xor_si128_emu(temp1, accB);
			accB = _mm_xor_si128_emu(temp2, accB);

			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);

			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto NEXT;
P_0_5: nextB = &&B_5; goto A_0;
P_0_6: nextB = &&B_6; goto A_0;
F_0_7:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			
			*prandexA  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufB);
			const __m128i temp2 = _mm_load_si128_emu(prandexB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			accB = _mm_xor_si128_emu(tempa3, accB);
			const __m128i temp4 = _mm_load_si128_emu(pbsfB);
			accB = _mm_xor_si128(temp4, accB);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexB, tempb2);
		
		
	}
	goto NEXT;
F_1_0:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accA = _mm_xor_si128_emu(clprod2, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexA);
			_mm_store_si128_emu(prandexA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accA = _mm_xor_si128_emu(add12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			
			*prandexB  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto NEXT;
F_1_1:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accA = _mm_xor_si128_emu(clprod2, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexA);
			_mm_store_si128_emu(prandexA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accA = _mm_xor_si128_emu(add12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accB = _mm_xor_si128_emu(clprod2, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexB);
			_mm_store_si128_emu(prandexB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accB = _mm_xor_si128_emu(add12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandB, tempb2);
			
	}
	goto NEXT;
F_1_2:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accA = _mm_xor_si128_emu(clprod2, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexA);
			_mm_store_si128_emu(prandexA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accA = _mm_xor_si128_emu(add12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accB = _mm_xor_si128_emu(add1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accB = _mm_xor_si128_emu(clprod22, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexB, tempb2);
			
	}
	goto NEXT;
P_1_3: nextB = &&B_3; goto A_1;
F_1_4:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accA = _mm_xor_si128_emu(clprod2, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexA);
			_mm_store_si128_emu(prandexA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accA = _mm_xor_si128_emu(add12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandA, tempb2);
			
	}
	{
			
			const __m128i *rc = prandB;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfB);
			__m128i temp2 = _mm_load_si128_emu(pbufB);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accB = _mm_xor_si128_emu(temp1, accB);
			accB = _mm_xor_si128_emu(temp2, accB);

			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);

			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto NEXT;
P_1_5: nextB = &&B_5; goto A_1;
P_1_6: nextB = &&B_6; goto A_1;
F_1_7:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accA = _mm_xor_si128_emu(clprod2, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexA);
			_mm_store_si128_emu(prandexA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accA = _mm_xor_si128_emu(add12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufB);
			const __m128i temp2 = _mm_load_si128_emu(prandexB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			accB = _mm_xor_si128_emu(tempa3, accB);
			const __m128i temp4 = _mm_load_si128_emu(pbsfB);
			accB = _mm_xor_si128(temp4, accB);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexB, tempb2);
		
		
	}
	goto NEXT;
F_2_0:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accA = _mm_xor_si128_emu(add1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accA = _mm_xor_si128_emu(clprod22, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			
			*prandexB  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto NEXT;
F_2_1:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accA = _mm_xor_si128_emu(add1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accA = _mm_xor_si128_emu(clprod22, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accB = _mm_xor_si128_emu(clprod2, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexB);
			_mm_store_si128_emu(prandexB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accB = _mm_xor_si128_emu(add12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandB, tempb2);
			
	}
	goto NEXT;
F_2_2:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accA = _mm_xor_si128_emu(add1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accA = _mm_xor_si128_emu(clprod22, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accB = _mm_xor_si128_emu(add1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accB = _mm_xor_si128_emu(clprod22, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexB, tempb2);
			
	}
	goto NEXT;
P_2_3: nextB = &&B_3; goto A_2;
F_2_4:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accA = _mm_xor_si128_emu(add1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accA = _mm_xor_si128_emu(clprod22, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexA, tempb2);
			
	}
	{
			
			const __m128i *rc = prandB;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfB);
			__m128i temp2 = _mm_load_si128_emu(pbufB);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accB = _mm_xor_si128_emu(temp1, accB);
			accB = _mm_xor_si128_emu(temp2, accB);

			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);

			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto NEXT;
P_2_5: nextB = &&B_5; goto A_2;
P_2_6: nextB = &&B_6; goto A_2;
F_2_7:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accA = _mm_xor_si128_emu(add1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accA = _mm_xor_si128_emu(clprod22, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexA, tempb2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufB);
			const __m128i temp2 = _mm_load_si128_emu(prandexB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			accB = _mm_xor_si128_emu(tempa3, accB);
			const __m128i temp4 = _mm_load_si128_emu(pbsfB);
			accB = _mm_xor_si128(temp4, accB);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexB, tempb2);
		
		
	}
	goto NEXT;
P_3_0: nextB = &&B_0; goto A_3;
P_3_1: nextB = &&B_1; goto A_3;
P_3_2: nextB = &&B_2; goto A_3;
P_3_3: nextB = &&B_3; goto A_3;
P_3_4: nextB = &&B_4; goto A_3;
P_3_5: nextB = &&B_5; goto A_3;
P_3_6: nextB = &&B_6; goto A_3;
P_3_7: nextB = &&B_7; goto A_3;
F_4_0:
	{
			
			const __m128i *rc = prandA;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfA);
			__m128i temp2 = _mm_load_si128_emu(pbufA);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accA = _mm_xor_si128_emu(temp1, accA);
			accA = _mm_xor_si128_emu(temp2, accA);

			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);

			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			
			*prandexB  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto NEXT;
F_4_1:
	{
			
			const __m128i *rc = prandA;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfA);
			__m128i temp2 = _mm_load_si128_emu(pbufA);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accA = _mm_xor_si128_emu(temp1, accA);
			accA = _mm_xor_si128_emu(temp2, accA);

			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);

			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accB = _mm_xor_si128_emu(clprod2, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexB);
			_mm_store_si128_emu(prandexB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accB = _mm_xor_si128_emu(add12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandB, tempb2);
			
	}
	goto NEXT;
F_4_2:
	{
			
			const __m128i *rc = prandA;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfA);
			__m128i temp2 = _mm_load_si128_emu(pbufA);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accA = _mm_xor_si128_emu(temp1, accA);
			accA = _mm_xor_si128_emu(temp2, accA);

			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);

			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accB = _mm_xor_si128_emu(add1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accB = _mm_xor_si128_emu(clprod22, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexB, tempb2);
			
	}
	goto NEXT;
P_4_3: nextB = &&B_3; goto A_4;
F_4_4:
	{
			
			const __m128i *rc = prandA;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfA);
			__m128i temp2 = _mm_load_si128_emu(pbufA);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accA = _mm_xor_si128_emu(temp1, accA);
			accA = _mm_xor_si128_emu(temp2, accA);

			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);

			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	{
			
			const __m128i *rc = prandB;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfB);
			__m128i temp2 = _mm_load_si128_emu(pbufB);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accB = _mm_xor_si128_emu(temp1, accB);
			accB = _mm_xor_si128_emu(temp2, accB);

			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);

			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto NEXT;
P_4_5: nextB = &&B_5; goto A_4;
P_4_6: nextB = &&B_6; goto A_4;
F_4_7:
	{
			
			const __m128i *rc = prandA;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfA);
			__m128i temp2 = _mm_load_si128_emu(pbufA);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accA = _mm_xor_si128_emu(temp1, accA);
			accA = _mm_xor_si128_emu(temp2, accA);

			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);

			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufB);
			const __m128i temp2 = _mm_load_si128_emu(prandexB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			accB = _mm_xor_si128_emu(tempa3, accB);
			const __m128i temp4 = _mm_load_si128_emu(pbsfB);
			accB = _mm_xor_si128(temp4, accB);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexB, tempb2);
		
		
	}
	goto NEXT;
P_5_0: nextB = &&B_0; goto A_5;
P_5_1: nextB = &&B_1; goto A_5;
P_5_2: nextB = &&B_2; goto A_5;
P_5_3: nextB = &&B_3; goto A_5;
P_5_4: nextB = &&B_4; goto A_5;
P_5_5: nextB = &&B_5; goto A_5;
P_5_6: nextB = &&B_6; goto A_5;
P_5_7: nextB = &&B_7; goto A_5;
P_6_0: nextB = &&B_0; goto A_6;
P_6_1: nextB = &&B_1; goto A_6;
P_6_2: nextB = &&B_2; goto A_6;
P_6_3: nextB = &&B_3; goto A_6;
P_6_4: nextB = &&B_4; goto A_6;
P_6_5: nextB = &&B_5; goto A_6;
P_6_6: nextB = &&B_6; goto A_6;
P_6_7: nextB = &&B_7; goto A_6;
F_7_0:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufA);
			const __m128i temp2 = _mm_load_si128_emu(prandexA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			accA = _mm_xor_si128_emu(tempa3, accA);
			const __m128i temp4 = _mm_load_si128_emu(pbsfA);
			accA = _mm_xor_si128(temp4, accA);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexA, tempb2);
		
		
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			
			*prandexB  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto NEXT;
F_7_1:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufA);
			const __m128i temp2 = _mm_load_si128_emu(prandexA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			accA = _mm_xor_si128_emu(tempa3, accA);
			const __m128i temp4 = _mm_load_si128_emu(pbsfA);
			accA = _mm_xor_si128(temp4, accA);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexA, tempb2);
		
		
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accB = _mm_xor_si128_emu(clprod2, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexB);
			_mm_store_si128_emu(prandexB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accB = _mm_xor_si128_emu(add12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandB, tempb2);
			
	}
	goto NEXT;
F_7_2:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufA);
			const __m128i temp2 = _mm_load_si128_emu(prandexA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			accA = _mm_xor_si128_emu(tempa3, accA);
			const __m128i temp4 = _mm_load_si128_emu(pbsfA);
			accA = _mm_xor_si128(temp4, accA);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexA, tempb2);
		
		
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accB = _mm_xor_si128_emu(add1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accB = _mm_xor_si128_emu(clprod22, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexB, tempb2);
			
	}
	goto NEXT;
P_7_3: nextB = &&B_3; goto A_7;
F_7_4:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufA);
			const __m128i temp2 = _mm_load_si128_emu(prandexA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			accA = _mm_xor_si128_emu(tempa3, accA);
			const __m128i temp4 = _mm_load_si128_emu(pbsfA);
			accA = _mm_xor_si128(temp4, accA);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexA, tempb2);
		
		
	}
	{
			
			const __m128i *rc = prandB;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfB);
			__m128i temp2 = _mm_load_si128_emu(pbufB);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accB = _mm_xor_si128_emu(temp1, accB);
			accB = _mm_xor_si128_emu(temp2, accB);

			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);

			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto NEXT;
P_7_5: nextB = &&B_5; goto A_7;
P_7_6: nextB = &&B_6; goto A_7;
F_7_7:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufA);
			const __m128i temp2 = _mm_load_si128_emu(prandexA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			accA = _mm_xor_si128_emu(tempa3, accA);
			const __m128i temp4 = _mm_load_si128_emu(pbsfA);
			accA = _mm_xor_si128(temp4, accA);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexA, tempb2);
		
		
	}
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufB);
			const __m128i temp2 = _mm_load_si128_emu(prandexB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			accB = _mm_xor_si128_emu(tempa3, accB);
			const __m128i temp4 = _mm_load_si128_emu(pbsfB);
			accB = _mm_xor_si128(temp4, accB);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexB, tempb2);
		
		
	}
	goto NEXT;
A_0:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			
			*prandexA  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto *nextB;
A_1:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accA = _mm_xor_si128_emu(clprod2, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexA);
			_mm_store_si128_emu(prandexA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accA = _mm_xor_si128_emu(add12, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandA, tempb2);
			
	}
	goto *nextB;
A_2:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexA);
			const __m128i temp2 = _mm_load_si128_emu(pbufA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accA = _mm_xor_si128_emu(add1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfA);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accA = _mm_xor_si128_emu(clprod12, accA);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accA = _mm_xor_si128_emu(clprod22, accA);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexA, tempb2);
			
	}
	goto *nextB;
A_3:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandA);
			const __m128i temp2 = _mm_load_si128_emu(pbsfA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);

			
			const int32_t divisor = (uint32_t)selectorA;

			accA = _mm_xor_si128_emu(add1, accA);

			const int64_t dividend = _mm_cvtsi128_si64_emu(accA);
                        asm(".global __use_realtime_division\n");
			const __m128i modulo = _mm_cvtsi32_si128_emu(VERUS_ABL_MOD(dividend, divisor));
			accA = _mm_xor_si128_emu(modulo, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			if (dividend & 1)
			{
				const __m128i temp12 = _mm_load_si128_emu(prandexA);
				_mm_store_si128_emu(prandexA, tempa2);

				const __m128i temp22 = _mm_load_si128_emu(pbufA);
				const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
				const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
				accA = _mm_xor_si128_emu(clprod12, accA);
				const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
				accA = _mm_xor_si128_emu(clprod22, accA);

				const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, temp12);
				const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
				_mm_store_si128_emu(prandA, tempb2);
			}
			else
			{
				*prandA = *prandexA;
				_mm_store_si128_emu(prandexA, tempa2);
				const __m128i tempb4 = _mm_load_si128_emu(pbufA);
				accA = _mm_xor_si128_emu(tempb4, accA);
			}
			
	}
	goto *nextB;
A_4:
	{
			
			const __m128i *rc = prandA;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfA);
			__m128i temp2 = _mm_load_si128_emu(pbufA);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accA = _mm_xor_si128_emu(temp1, accA);
			accA = _mm_xor_si128_emu(temp2, accA);

			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);

			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto *nextB;
A_5:
	{
			
			const __m128i *buftmp = pbsfA;
			__m128i tmp; 

			int64_t rounds = selectorA >> 61; 
			__m128i *rc = prandA;
			uint64_t aesround = 0;
			__m128i onekey, temp1a, temp1b, temp2a, temp2b;

































#pragma clang loop unroll(full)
                        
                        for ( uint64_t count = 8; count--;  )
                        {
                                if ( rounds >= 0 )
                                {
                                                onekey = _mm_load_si128_emu(rc++);
                                                

                                                if (VERUS_ABL_INNER(selectorA, rounds))
                                                {
                                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbufA : pbsfA);  
                                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
                                                        const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                                        accA = _mm_xor_si128_emu(clprod1, accA);
                                                }
                                                else
                                                {
                                                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbsfA : pbufA);  
                                                        const uint64_t roundidx = aesround++ << 2;
                                                        AES2(onekey, temp2, roundidx);

                                                        MIX2_EMU(onekey, temp2);

                                                        accA ^= onekey ^ temp2;
                                                }
                                rounds--;
                                }
                        }


			const __m128i tempa1 = _mm_load_si128_emu(prandA);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accA, tempa1);
			*prandA = *prandexA;
			*prandexA = _mm_xor_si128_emu(tempa1, tempa2);

			
	}
	goto *nextB;
A_6:
	{   
             const __m128i *buftmp = pbsfA;
                __m128i tmp; 

                int64_t rounds = selectorA >> 61; 
                __m128i *rc = prandA;
                __m128i onekey;
























  
#pragma clang loop unroll(full)
                for ( uint64_t count = 8; count--;  )
                {
                        if ( rounds >= 0 )
                        {
                                    onekey = _mm_load_si128_emu(rc++);
                                    if (VERUS_ABL_INNER(selectorA, rounds))
                                    {
                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbufA : pbsfA );
                                        onekey = _mm_xor_si128_emu(onekey, temp2);
                                        
  		                        const int32_t divisor = (uint32_t)selectorA;
                                        const int64_t dividend = _mm_cvtsi128_si64(onekey);
                                        asm(".global __use_realtime_division\n");
                                        const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor));
                                        accA = _mm_xor_si128_emu(modulo, accA);
                                    }
                                    else
                                    {
                                        const __m128i temp4 = _mm_load_si128_emu(rounds & 1 ? pbsfA : pbufA);
                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp4);
                                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(accA, onekey);
                                        accA = _mm_xor_si128_emu(clprod2, accA);
                                    }
                                    rounds--;
                        }
                }


                *prandA = _mm_xor_si128_emu(*prandexA, accA);
                _mm_store_si128_emu(prandexA, onekey);
                
	}
	goto *nextB;
A_7:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufA);
			const __m128i temp2 = _mm_load_si128_emu(prandexA);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accA = _mm_xor_si128_emu(clprod1, accA);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accA, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandA);
			_mm_store_si128_emu(prandA, tempa2);

			accA = _mm_xor_si128_emu(tempa3, accA);
			const __m128i temp4 = _mm_load_si128_emu(pbsfA);
			accA = _mm_xor_si128(temp4, accA);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accA, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexA, tempb2);
		
		
	}
	goto *nextB;
B_0:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbufB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			
			*prandexB  = _mm_xor_si128_emu(tempb1, temp12);
			
			
	}
	goto NEXT;
B_1:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);
			const __m128i clprod2 = _mm_clmulepi64_si128_emu(temp2, temp2, 0x10);
			accB = _mm_xor_si128_emu(clprod2, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandexB);
			_mm_store_si128_emu(prandexB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			accB = _mm_xor_si128_emu(add12, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandB, tempb2);
			
	}
	goto NEXT;
B_2:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandexB);
			const __m128i temp2 = _mm_load_si128_emu(pbufB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			accB = _mm_xor_si128_emu(add1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			const __m128i temp12 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			const __m128i temp22 = _mm_load_si128_emu(pbsfB);
			const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
			const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
			accB = _mm_xor_si128_emu(clprod12, accB);
			const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
			accB = _mm_xor_si128_emu(clprod22, accB);

			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
			_mm_store_si128_emu(prandexB, tempb2);
			
	}
	goto NEXT;
B_3:
	{
			const __m128i temp1 = _mm_load_si128_emu(prandB);
			const __m128i temp2 = _mm_load_si128_emu(pbsfB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);

			
			const int32_t divisor = (uint32_t)selectorB;

			accB = _mm_xor_si128_emu(add1, accB);

			const int64_t dividend = _mm_cvtsi128_si64_emu(accB);
                        asm(".global __use_realtime_division\n");
			const __m128i modulo = _mm_cvtsi32_si128_emu(VERUS_ABL_MOD(dividend, divisor));
			accB = _mm_xor_si128_emu(modulo, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp1);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp1);

			if (dividend & 1)
			{
				const __m128i temp12 = _mm_load_si128_emu(prandexB);
				_mm_store_si128_emu(prandexB, tempa2);

				const __m128i temp22 = _mm_load_si128_emu(pbufB);
				const __m128i add12 = _mm_xor_si128_emu(temp12, temp22);
				const __m128i clprod12 = _mm_clmulepi64_si128_emu(add12, add12, 0x10);
				accB = _mm_xor_si128_emu(clprod12, accB);
				const __m128i clprod22 = _mm_clmulepi64_si128_emu(temp22, temp22, 0x10);
				accB = _mm_xor_si128_emu(clprod22, accB);

				const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, temp12);
				const __m128i tempb2 = _mm_xor_si128_emu(tempb1, temp12);
				_mm_store_si128_emu(prandB, tempb2);
			}
			else
			{
				*prandB = *prandexB;
				_mm_store_si128_emu(prandexB, tempa2);
				const __m128i tempb4 = _mm_load_si128_emu(pbufB);
				accB = _mm_xor_si128_emu(tempb4, accB);
			}
			
	}
	goto NEXT;
B_4:
	{
			
			const __m128i *rc = prandB;
			__m128i tmp;

			__m128i temp1 = _mm_load_si128_emu(pbsfB);
			__m128i temp2 = _mm_load_si128_emu(pbufB);

			AES2(temp1, temp2, 0);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 4);
			MIX2_EMU(temp1, temp2);

			AES2(temp1, temp2, 8);
			MIX2_EMU(temp1, temp2);

			accB = _mm_xor_si128_emu(temp1, accB);
			accB = _mm_xor_si128_emu(temp2, accB);

			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);

			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);
			
	}
	goto NEXT;
B_5:
	{
			
			const __m128i *buftmp = pbsfB;
			__m128i tmp; 

			int64_t rounds = selectorB >> 61; 
			__m128i *rc = prandB;
			uint64_t aesround = 0;
			__m128i onekey, temp1a, temp1b, temp2a, temp2b;

































#pragma clang loop unroll(full)
                        
                        for ( uint64_t count = 8; count--;  )
                        {
                                if ( rounds >= 0 )
                                {
                                                onekey = _mm_load_si128_emu(rc++);
                                                

                                                if (VERUS_ABL_INNER(selectorB, rounds))
                                                {
                                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbufB : pbsfB);  
                                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp2);
                                                        const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                                        accB = _mm_xor_si128_emu(clprod1, accB);
                                                }
                                                else
                                                {
                                                        __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbsfB : pbufB);  
                                                        const uint64_t roundidx = aesround++ << 2;
                                                        AES2(onekey, temp2, roundidx);

                                                        MIX2_EMU(onekey, temp2);

                                                        accB ^= onekey ^ temp2;
                                                }
                                rounds--;
                                }
                        }


			const __m128i tempa1 = _mm_load_si128_emu(prandB);
			const __m128i tempa2 = _mm_mulhrs_epi16_emu(accB, tempa1);
			*prandB = *prandexB;
			*prandexB = _mm_xor_si128_emu(tempa1, tempa2);

			
	}
	goto NEXT;
B_6:
	{   
             const __m128i *buftmp = pbsfB;
                __m128i tmp; 

                int64_t rounds = selectorB >> 61; 
                __m128i *rc = prandB;
                __m128i onekey;
























  
#pragma clang loop unroll(full)
                for ( uint64_t count = 8; count--;  )
                {
                        if ( rounds >= 0 )
                        {
                                    onekey = _mm_load_si128_emu(rc++);
                                    if (VERUS_ABL_INNER(selectorB, rounds))
                                    {
                                        const __m128i temp2 = _mm_load_si128_emu(rounds & 1 ? pbufB : pbsfB );
                                        onekey = _mm_xor_si128_emu(onekey, temp2);
                                        
  		                        const int32_t divisor = (uint32_t)selectorB;
                                        const int64_t dividend = _mm_cvtsi128_si64(onekey);
                                        asm(".global __use_realtime_division\n");
                                        const __m128i modulo = _mm_cvtsi32_si128(VERUS_ABL_MOD(dividend, divisor));
                                        accB = _mm_xor_si128_emu(modulo, accB);
                                    }
                                    else
                                    {
                                        const __m128i temp4 = _mm_load_si128_emu(rounds & 1 ? pbsfB : pbufB);
                                        const __m128i add1 = _mm_xor_si128_emu(onekey, temp4);
                                        onekey = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
                                        const __m128i clprod2 = _mm_mulhrs_epi16_emu(accB, onekey);
                                        accB = _mm_xor_si128_emu(clprod2, accB);
                                    }
                                    rounds--;
                        }
                }


                *prandB = _mm_xor_si128_emu(*prandexB, accB);
                _mm_store_si128_emu(prandexB, onekey);
                
	}
	goto NEXT;
B_7:
	{
			const __m128i temp1 = _mm_load_si128_emu(pbufB);
			const __m128i temp2 = _mm_load_si128_emu(prandexB);
			const __m128i add1 = _mm_xor_si128_emu(temp1, temp2);
			const __m128i clprod1 = _mm_clmulepi64_si128_emu(add1, add1, 0x10);
			accB = _mm_xor_si128_emu(clprod1, accB);

			const __m128i tempa1 = _mm_mulhrs_epi16_emu(accB, temp2);
			const __m128i tempa2 = _mm_xor_si128_emu(tempa1, temp2);

			const __m128i tempa3 = _mm_load_si128_emu(prandB);
			_mm_store_si128_emu(prandB, tempa2);

			accB = _mm_xor_si128_emu(tempa3, accB);
			const __m128i temp4 = _mm_load_si128_emu(pbsfB);
			accB = _mm_xor_si128(temp4, accB);
			const __m128i tempb1 = _mm_mulhrs_epi16_emu(accB, tempa3);
			const __m128i tempb2 = _mm_xor_si128_emu(tempb1, tempa3);
			_mm_store_si128_emu(prandexB, tempb2);
		
		
	}
	goto NEXT;
NEXT:
	if (++i < 32) goto ROUND;
	accA = _mm_xor_si128_emu(accA, _mm_cvtsi32_si128_emu(0x10000));
	accB = _mm_xor_si128_emu(accB, _mm_cvtsi32_si128_emu(0x10000));
	out[0] = precompReduction64_port(accA);
	out[1] = precompReduction64_port(accB);
}
#endif /* VERUS_FUSE */
/* END GENERATED x2fuse */
#endif /* VERUS_X2 */

// hashes 64 bytes only by doing a carryless multiplication and reduction of the repeated 64 byte sequence 16 times, 
// returning a 64 bit hash value
uint64_t verusclhash_port2_2(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand, uint16_t * __restrict fixrandex,
								 __m128i *g_prand, __m128i *g_prandex) {
    const unsigned int  m = 128;// we process the data in chunks of 16 cache lines
    __m128i * rs64 = (__m128i *)random;
    const __m128i * string = (const __m128i *) buf;

    __m128i  acc = __verusclmulwithoutreduction64alignedrepeat_port2_2(rs64, string, keyMask, fixrand, fixrandex, g_prand, g_prandex);
    //acc = _mm_xor_si128_emu(acc, lazyLengthHash_port(1024, 64));
    acc = _mm_xor_si128_emu(acc, _mm_cvtsi32_si128_emu(0x10000));
    return precompReduction64_port(acc);
}

/* variant "pristine": like verusclhash_port2_2 but saves nothing; the caller restores the key positions
 * listed in fixrand/fixrandex from a pristine copy of the key (verus_fixkey_pristine in verus_clhash.h). */
uint64_t verusclhash_port2_2_nojournal(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand,
		uint16_t * __restrict fixrandex) {
    __m128i  acc = verusclmul_repeat_port2_2_t<false>((__m128i *)random, (const __m128i *)buf, keyMask, fixrand, fixrandex, 0, 0);
    acc = _mm_xor_si128_emu(acc, _mm_cvtsi32_si128_emu(0x10000));
    return precompReduction64_port(acc);
}
/* the same with the four common operands loaded before the case jump ("preload", VERUS_PRE1=1) */
uint64_t verusclhash_port2_2_nojournal_pre(void * random, const unsigned char buf[64], uint64_t keyMask, uint16_t *  __restrict fixrand,
		uint16_t * __restrict fixrandex) {
    __m128i  acc = verusclmul_repeat_port2_2_t<false, true>((__m128i *)random, (const __m128i *)buf, keyMask, fixrand, fixrandex, 0, 0);
    acc = _mm_xor_si128_emu(acc, _mm_cvtsi32_si128_emu(0x10000));
    return precompReduction64_port(acc);
}
