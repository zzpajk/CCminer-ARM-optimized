/*
* Equihash solver interface for ccminer (compatible with linux and windows)
* Solver taken from nheqminer, by djeZo (and NiceHash)
* tpruvot - 2017 (GPL v3)
*/
//#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
//#include <stringlib.h>   // dmi
#define VERUS_KEY_SIZE 8832
#define VERUS_KEY_SIZE128 552
#include <stdexcept>
#include <vector>

#include "verus_clhash.h"
#include "uint256.h"
//#include "hash.h"
#include <miner.h>
//#include "primitives/block.h"

#include "sse2neon.h"
extern "C" 
{
//#include "haraka.h"
#include "haraka_portable.h"
#include "haraka.h"
}
#include "verus_x2.h"

enum
{
	// primary actions
	SER_NETWORK = (1 << 0),
	SER_DISK = (1 << 1),
	SER_GETHASH = (1 << 2),
};
// input here is 140 for the header and 1344 for the solution (equi.cpp)
static const int PROTOCOL_VERSION = 170002;

//#include <cuda_helper.h>

#define EQNONCE_OFFSET 30 /* 27:34 */
#define NONCE_OFT EQNONCE_OFFSET

static bool init[MAX_GPUS] = { 0 };

static __thread uint32_t throughput = 0;



#ifndef htobe32
#define htobe32(x) swab32(x)
#endif

void GenNewCLKey(unsigned char *seedBytes32, __m128i *keyback)
{
	// generate a new key by chain hashing with Haraka256 from the last curbuf
	uint32_t n256blks = VERUS_KEY_SIZE >> 5;  //8832 >> 5
	uint32_t nbytesExtra = VERUS_KEY_SIZE & 0x1f;  //8832 & 0x1f
	unsigned char *pkey = (unsigned char*)keyback;
	unsigned char *psrc = seedBytes32;
#pragma clang unroll(full) vectorize(enable)
	for (uint32_t i = 0; i < n256blks; i++)
	{
		haraka256_port(pkey, psrc);

		psrc = pkey;
		pkey += 32;
	}
	//if (nbytesExtra)
	//{
	//	unsigned char buf[32];
	//	haraka256_port(buf, psrc);
	//	memcpy(pkey, buf, nbytesExtra);
	//}
}

//extern "C" void FixKey(uint16_t *fixrand, uint16_t *fixrandex, __m128i *keyback, __m128i *keyback_master)
inline void FixKey(uint16_t * __restrict fixrand,  uint16_t * __restrict fixrandex, __m128i *  __restrict keyback,
	__m128i * __restrict g_prand, __m128i * __restrict g_prandex)
{

        for ( int64_t i = 31; i > -1; i-- )
	{
		keyback[fixrand[i]] = g_prand[i];
		keyback[fixrandex[i]] = g_prandex[i];
		//printf("%" PRIu32 " %" PRIu32 "\n",fixrand[i],fixrandex[i]);
	}

//	for ( uint8_t i = 32; i--;  )
//	{
//		keyback[fixrand[i]] = keyback_master[fixrand[i]];
//		//printf("%" PRIu32 " %" PRIu32 "\n",fixrand[i],fixrandex[i]);
//	}
//
//	for ( uint8_t i = 32; i--;  )
//	{
//		keyback[fixrandex[i]] = keyback_master[fixrandex[i]];
//		//printf("%" PRIu32 " %" PRIu32 "\n",fixrand[i],fixrandex[i]);
//	}

	//printf("--------------\n");
	//note - I tried memcpy(keyback,keyback_master,VERUS_KEY_SIZE) instead of this loop
	//and while it worked  it was noticeably slower to copy those 8832 bytes 
	//than to just do the random 64 array insertions above.
	//__memcpy_aarch64(keyback, keyback_master, VERUS_KEY_SIZE);

//#pragma clang loop unroll(full) vectorize(enable)
//	for ( uint16_t i = 0; i < 552; i++)
//	{
//	 		keyback[i] = keyback_master[i];
//	}

}


extern "C" void VerusHashHalf(void *result2, unsigned char *data, size_t len)
{
	alignas(16) unsigned char buf1[64] = { 0 }, buf2[64];
	unsigned char *curBuf = buf1, *result = buf2;
	size_t curPos = 0;
	//unsigned char result[64];
	curBuf = buf1;
	result = buf2;
	curPos = 0;
	std::fill(buf1, buf1 + sizeof(buf1), 0);

	unsigned char *tmp;

	load_constants_port();

	// digest up to 32 bytes at a time
	for (int pos = 0; pos < len; )
	{
		int room = 32 - curPos;

		if (len - pos >= room)
		{
			memcpy(curBuf + 32 + curPos, data + pos, room);
			haraka512_port(result, curBuf);
			tmp = curBuf;
			curBuf = result;
			result = tmp;
			pos += room;
			curPos = 0;
		}
		else
		{
			memcpy(curBuf + 32 + curPos, data + pos, len - pos);
			curPos += len - pos;
			pos = len;
		}
	}

	memcpy(curBuf + 47, curBuf, 16);
	memcpy(curBuf + 63, curBuf, 1);
	//	FillExtra((__m128i *)curBuf);
	memcpy(result2, curBuf, 64);
};




extern "C" void Verus2hash(unsigned char *hash, unsigned char *curBuf, unsigned char *nonce,
        __m128i * __restrict data_key, uint8_t *gpu_init, uint16_t * __restrict fixrand, uint16_t * __restrict fixrandex, __m128i * __restrict g_prand,
        __m128i * __restrict g_prandex, int version)
{
	//uint64_t mask = VERUS_KEY_SIZE128; //552
	//if (!gpu_init[0]) {
	//	GenNewCLKey(curBuf, data_key);  //data_key a global static 2D array data_key[16][8832];
	//	gpu_init[0] = 1;
	//
	//}
	memcpy(curBuf + 47, curBuf, 16);
	memcpy(curBuf + 63, curBuf, 1);
	//	FillExtra((__m128i *)curBuf);

	uint64_t intermediate;
	memcpy(curBuf + 32, nonce, 15);  //copy the 15bytes nonce

	intermediate = verusclhash_port2_2(data_key, curBuf, 511, fixrand, fixrandex, g_prand, g_prandex);

	//__builtin_prefetch(&data_key[fixrand[0]],1,0);
	//__builtin_prefetch(&data_key[fixrandex[0]],1,0);
	//__builtin_prefetch(&g_prand[0],0,0);
	//__builtin_prefetch(&g_prandex[0],0,0);

	//FillExtra

	memcpy(curBuf + 47, &intermediate, 8);
	memcpy(curBuf + 55, &intermediate, 8);
	memcpy(curBuf + 63, &intermediate, 1);
	//intermediate &= 511;
 	haraka512_keyed(hash, curBuf, data_key + ( intermediate & 511 ));
	//__builtin_prefetch(&data_key[272],1,3);
	//__builtin_prefetch(&data_key_master[272],0,3);
	FixKey(fixrand, fixrandex, data_key, g_prand, g_prandex);
}
#ifdef VERUS_PRISTINE
/* variant "pristine" (plain single-nonce loop only): no per-round journal of the old key values; the
 * touched positions are copied back from a pristine copy of the key made once per scan call. */
static inline void Verus2hash_pristine(unsigned char *hash, unsigned char *curBuf, unsigned char *nonce,
        __m128i * __restrict data_key, const __m128i * __restrict pristine, uint16_t * __restrict fixrand, uint16_t * __restrict fixrandex)
{
	memcpy(curBuf + 47, curBuf, 16);
	memcpy(curBuf + 63, curBuf, 1);
	memcpy(curBuf + 32, nonce, 15);
	uint64_t intermediate = verusclhash_port2_2_nojournal(data_key, curBuf, 511, fixrand, fixrandex);
	memcpy(curBuf + 47, &intermediate, 8);
	memcpy(curBuf + 55, &intermediate, 8);
	memcpy(curBuf + 63, &intermediate, 1);
	haraka512_keyed(hash, curBuf, data_key + (intermediate & 511));
	verus_fixkey_pristine(fixrand, fixrandex, data_key, pristine);
}
#endif

#ifdef _WIN32

#define posix_memalign(p, a, s) (((*(p)) = _aligned_malloc((s), (a))), *(p) ?0 :errno)
#endif


#ifdef VERUS_X2
/* How many nonces to hash in lockstep on the core this thread is running on.
 * VERUS_AUTO: in-order ARM cores (A34/A35/A53/A55/A510/A520, Kryo Silver) do not overlap the lanes and lose a little
 * (measured -3% on an A53), so they use the plain single-nonce loop; every other core uses VERUS_LANES.
 * Without VERUS_AUTO every core uses VERUS_LANES. Decided once per scan call from the current cpu. */
#ifdef VERUS_AUTO
#include <stdio.h>
#include <sched.h>
static uint8_t g_inorder[1024];
static uint16_t g_impl[1024], g_part[1024];
static void verus_scan_cpuinfo()
{
	FILE *f = fopen("/proc/cpuinfo", "r");
	if (!f) return;
	char line[256]; int cpu = -1; unsigned impl = 0, part = 0; bool have_i = false, have_p = false;
	while (fgets(line, sizeof(line), f)) {
		int v; unsigned u;
		if (sscanf(line, "processor : %d", &v) == 1) { cpu = v; have_i = have_p = false; }
		else if (sscanf(line, "CPU implementer : 0x%x", &u) == 1) { impl = u; have_i = true; }
		else if (sscanf(line, "CPU part : 0x%x", &u) == 1) { part = u; have_p = true; }
		if (cpu >= 0 && cpu < 1024 && have_i && have_p) {
			/* in-order cores: Cortex-A34/A35/A53/A55/A510/A520, and Qualcomm Kryo "Silver" cores, which are
			 * A53/A55 derivatives with Qualcomm part numbers (Snapdragon 835: 0x801, 845: 0x803, 855: 0x805) */
			g_inorder[cpu] = (impl == 0x41 && (part == 0xd02 || part == 0xd03 || part == 0xd04 || part == 0xd05 || part == 0xd46 || part == 0xd80))
				|| (impl == 0x51 && (part == 0x801 || part == 0x803 || part == 0x805));
			g_impl[cpu] = (uint16_t)impl; g_part[cpu] = (uint16_t)part;
			have_i = have_p = false;
		}
	}
	fclose(f);
}
#endif
/* x2percore: which two-nonce code to use on an out-of-order core (SEL bit 0 = branch-free choice in
 * case 0x14, bit 1 = same in case 0x18, which costs extra divides). Measured on S8/S20:
 *   Mongoose M2 (0x53:0x001, slow divider): plain x2 best, sel2 -3..-4%
 *   Mongoose M5 (0x53:0x004): sel2 +8% over x2;  Cortex-A76 (0x41:0xd0b): sel2 +4% over x2
 * Other Mongoose generations are not measured yet and get bit 0 only. VERUS_SEL=0..3 in the environment
 * overrides the choice for all out-of-order cores (for testing); VERUS_SEL=7 adds the fully branch-free
 * case 0x14 (x2sel3). */
static int verus_sel_for_cpu(int cpu)
{
	int sel = VERUS_SEL_DEFAULT;
#ifdef VERUS_PERCORE
	if (cpu >= 0 && cpu < 1024) {
		if (g_impl[cpu] == 0x53) sel = (g_part[cpu] == 0x001) ? 0 : (g_part[cpu] == 0x004) ? 3 : 1;
		else sel = 3;
	}
#ifdef VERUS_PERCORE3
	sel |= 4;   /* x2percore3: also the fully branch-free case 0x14 on every out-of-order core */
#endif
	static int env = -2;
	if (env == -2) { const char *e = getenv("VERUS_SEL"); env = (e && e[0] >= '0' && e[0] <= '7' && !e[1]) ? e[0] - '0' : -1; }
	if (env >= 0) sel = env;
#else
	(void)cpu;
#endif
	return sel;
}

static int verus_lanes_for_this_core(int thr_id, int *sel)
{
#ifdef VERUS_AUTO
	static bool once = (verus_scan_cpuinfo(), true); (void)once;
	int cpu = sched_getcpu();
	int lanes = (cpu >= 0 && cpu < 1024 && g_inorder[cpu]) ? 1 : VERUS_LANES;
	/* testing aid: VERUS_LANES=1 forces the plain single-nonce loop on every core, VERUS_LANES=N (the
	 * compiled lane count) forces the multi-nonce loop on every core, in-order ones included */
	static int envl = -2;
	if (envl == -2) { const char *e = getenv("VERUS_LANES"); envl = (e && (e[0] == '1' || e[0] - '0' == VERUS_LANES) && !e[1]) ? e[0] - '0' : -1; }
	if (envl > 0) lanes = envl;
	*sel = (lanes > 1 && VERUS_LANES == 2) ? verus_sel_for_cpu(cpu) : 0;
	static __thread int logged = 0;
	if (!logged) { logged = 1; applog(LOG_INFO, "Verus thread %d on cpu %d: %d nonce(s) per step%s", thr_id, cpu, lanes,
		lanes == 1 ? "" : (*sel == 7 ? ", sel3" : *sel == 5 ? ", sel14+full14" : *sel == 4 ? ", full14" : *sel == 3 ? ", sel2" : *sel == 1 ? ", sel" : *sel == 2 ? ", sel18" : "")); }
	return lanes;
#else
	(void)thr_id;
	*sel = (VERUS_LANES == 2) ? VERUS_SEL_DEFAULT : 0;
	return VERUS_LANES;
#endif
}
#endif


#ifdef VERUS_X2
struct verus_scan_ctx {
	struct work *work; int thr_id; uint32_t max_nonce; unsigned long *hashes_done; uint32_t nonce_buf;
	uint8_t *nonceSpace; uint8_t *full_data; uint8_t *sol_data; uint32_t Htarg; uint32_t *vhash;
	__m128i *data_key; uint16_t *fixrand; uint16_t *fixrandex; __m128i *gp; __m128i *gpx;
	uint8_t *blockhash_half; struct timeval tv_start;
};

/* variants x2/x3/x4/auto: VERUS_LANES nonces per iteration, each lane with its own key copy (see verus_x2.h). */
template<int SEL>
static __attribute__((noinline)) void verus_scan_lanes(struct verus_scan_ctx *c)
{
	struct work *work = c->work;
	uint32_t nonce_buf = c->nonce_buf;
	const uint32_t Htarg = c->Htarg;
	uint8_t *nonceSpace = c->nonceSpace;
	struct timeval tv_now;
	const int NL = VERUS_LANES;
	alignas(64) __m128i keyL[VERUS_LANES - 1][VERUS_KEY_SIZE128 + 8];
	alignas(64) __m128i gpL[VERUS_LANES - 1][32], gpxL[VERUS_LANES - 1][32];
	alignas(16) uint8_t halfL[VERUS_LANES - 1][64];
	uint16_t fixrandL[VERUS_LANES - 1][32], fixrandexL[VERUS_LANES - 1][32];
	struct verus_lane L[VERUS_LANES];
	L[0] = (struct verus_lane){ c->data_key, c->fixrand, c->fixrandex, c->gp, c->gpx, c->blockhash_half };
	for (int l = 1; l < NL; l++) {
		memcpy(keyL[l - 1], c->data_key, VERUS_KEY_SIZE128 * sizeof(__m128i));
		memcpy(halfL[l - 1], c->blockhash_half, 64);
		L[l] = (struct verus_lane){ keyL[l - 1], fixrandL[l - 1], fixrandexL[l - 1], gpL[l - 1], gpxL[l - 1], halfL[l - 1] };
	}
	uint8_t nonceL[VERUS_LANES][15];
	uint32_t vh[VERUS_LANES][8];
	unsigned char *hp[VERUS_LANES]; const unsigned char *np[VERUS_LANES];
	for (int l = 0; l < NL; l++) { hp[l] = (unsigned char *)vh[l]; np[l] = nonceL[l]; }
	throughput = NL;
	do {
		*c->hashes_done = nonce_buf + throughput;
		for (int l = 0; l < NL; l++) {
			memcpy(nonceL[l], nonceSpace, 15);
			((uint32_t *)(&nonceL[l][11]))[0] = nonce_buf + l;
		}
		memset(vh, 0, sizeof(vh));

		Verus2hash_xN<VERUS_LANES, (VERUS_LANES == 2 ? SEL : 0)>(hp, L, np);

		for (int lane = 0; lane < NL; lane++) {
			if (vh[lane][7] <= Htarg) {
				((uint32_t *)(&nonceSpace[11]))[0] = nonce_buf + lane;
				memcpy(c->vhash, vh[lane], 8 * sizeof(uint32_t));
				work->valid_nonces++;
				memcpy(work->data, c->full_data, 140);
				int nonce = work->valid_nonces - 1;
				memcpy(work->extra, c->sol_data, 1347);
				memcpy(work->extra + 1332, nonceSpace, 15);
				bn_store_hash_target_ratio(c->vhash, work->target, work, nonce);
				work->nonces[work->valid_nonces - 1] = ((uint32_t*)c->full_data)[NONCE_OFT];
				return;
			}
		}
		if ( __builtin_expect ( (uint64_t)throughput + (uint64_t)nonce_buf >= (uint64_t)c->max_nonce, 0) )
			break;
		nonce_buf += throughput;
		if (opt_benchmark && (nonce_buf & 0x3FF) == 0) {
			gettimeofday(&tv_now, NULL);
			if ((int64_t)(tv_now.tv_sec - c->tv_start.tv_sec) * 1000000 + (tv_now.tv_usec - c->tv_start.tv_usec) >= 1000000)
				break;
		}
	} while (!work_restart[c->thr_id].restart);
}
#endif

extern "C" int scanhash_verus(int thr_id, struct work *work, uint32_t max_nonce, unsigned long *hashes_done)
{
	//uint32_t _ALIGN(16) endiandata[35];
	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;

	uint8_t blockhash_half[64] = { 0 };
	uint8_t gpuinit = 0;
	struct timeval tv_start, tv_end, tv_now, diff;
	double secs, solps;

	//__m128i *data_key =  (__m128i *)malloc(VERUS_KEY_SIZE);
	__m128i data[VERUS_KEY_SIZE] __attribute__ ((aligned(64)));
	__m128i *data_key = &data[0];
	//__m128i *data_key_prand =  (__m128i *)malloc(32 * 16);
	__m128i data_key_rand[32 * 16] __attribute__ ((aligned(64))); 
	__m128i *data_key_prand = &data_key_rand[0];
	//__m128i *data_key_prandex =  (__m128i *)malloc(32 * 16);
	__m128i data_key_randex[32 * 16] __attribute__ ((aligned(64)));  
	__m128i *data_key_prandex = &data_key_randex[0];
	//__m128i *data_key_prand = data_key + VERUS_KEY_SIZE128 ;
	//__m128i *data_key_prandex = data_key + VERUS_KEY_SIZE128 + 32;

	uint32_t nonce_buf = 0;
	uint16_t fixrand[32] __attribute__ ((aligned(64)));
	uint16_t fixrandex[32] __attribute__ ((aligned(64)));

	unsigned char block_41970[3] = { 0xfd, 0x40, 0x05};
	uint8_t  full_data[140 + 3 + 1344] = { 0 };
	uint8_t* sol_data = &full_data[140];


	memcpy(full_data, pdata, 140);
	memcpy(sol_data, block_41970, 3);
	memcpy(sol_data + 3, work->solution, 1344);
	uint8_t version = work->solution[0];
	uint8_t nonceSpace[15] = {0};  //pool nonce (32bit) + round(32bit) + thrd id (byte) + padding(2bytes) + counting nonce(32bit)

    if (version >= 7 && work->solution[5] > 0) {


        // clear non-canonical data from header/solution before hashing; required for merged mining
                memset(full_data + 4, 0, 96);                        // hashPrevBlock, hashMerkleRoot, hashFinalSaplingRoot
                memset(full_data + 4 + 32 + 32 + 32 + 4, 0, 4);      // nBits
                memset(full_data + 4 + 32 + 32 + 32 + 4 + 4, 0, 32); // nNonce
                memset(sol_data + 3 + 8, 0, 64);                     // hashPrevMMRRoot, hashBlockMMRRoot
                memcpy(nonceSpace, &pdata[EQNONCE_OFFSET - 3], 7 );
                memcpy(nonceSpace + 7, &pdata[EQNONCE_OFFSET + 2], 4 );
        }

	uint32_t vhash[8] = { 0 };

	VerusHashHalf(blockhash_half, (unsigned char*)full_data, 1487);
	GenNewCLKey((unsigned char*)blockhash_half, data_key);  //data_key a global static 2D array data_key[16][8832];
#ifdef VERUS_PRISTINE
	__m128i pristine_key[VERUS_KEY_SIZE128] __attribute__ ((aligned(64)));
	memcpy(pristine_key, data_key, sizeof(pristine_key));
#endif

	//__builtin_prefetch(&fixrand[0],1,3);
	//__builtin_prefetch(&fixrand[15],1,3);
	//__builtin_prefetch(&fixrandex[0],1,3);
	//__builtin_prefetch(&fixrandex[15],1,3);

	gettimeofday(&tv_start, NULL);

	throughput = 1;
	const uint32_t Htarg = ptarget[7];
#ifdef VERUS_X2
	int sel = 0;
	if (verus_lanes_for_this_core(thr_id, &sel) > 1)
	{
		/* The multi-nonce loop lives in its own noinline function so that this function (and the plain loop
		 * below, which is the baseline code) is compiled exactly as in the baseline build. */
		struct verus_scan_ctx c = { work, thr_id, max_nonce, hashes_done, nonce_buf, nonceSpace, full_data, sol_data,
			Htarg, vhash, data_key, fixrand, fixrandex, data_key_prand, data_key_prandex, blockhash_half, tv_start };
		switch (sel) {
		case 7:  verus_scan_lanes<7>(&c); break;
		case 5:  verus_scan_lanes<5>(&c); break;
		case 4:  verus_scan_lanes<4>(&c); break;
		case 1:  verus_scan_lanes<1>(&c); break;
		case 2:  verus_scan_lanes<2>(&c); break;
		case 3:  verus_scan_lanes<3>(&c); break;
		default: verus_scan_lanes<0>(&c); break;
		}
		goto out;
	}
#endif
	do {

		*hashes_done = nonce_buf + throughput;
				((uint32_t *)(&nonceSpace[11]))[0] = nonce_buf;

		((uint32_t *)(&nonceSpace[11]))[0] = nonce_buf;

#ifdef VERUS_PRISTINE
		Verus2hash_pristine((unsigned char *)vhash, (unsigned char *)blockhash_half, nonceSpace, data_key,
				pristine_key, fixrand, fixrandex);
#else
		Verus2hash((unsigned char *)vhash, (unsigned char *)blockhash_half, nonceSpace, data_key,
				&gpuinit, fixrand, fixrandex , data_key_prand, data_key_prandex, version);
#endif

		if (  vhash[7] <= Htarg )
		{
			work->valid_nonces++;
			memcpy(work->data, full_data, 140);
			int nonce = work->valid_nonces - 1;
			memcpy(work->extra, sol_data, 1347);
			memcpy(work->extra + 1332, nonceSpace, 15);  //copy in the valid nonce 15 bytes to the solution part
			bn_store_hash_target_ratio(vhash, work->target, work, nonce);

			work->nonces[work->valid_nonces - 1] = ((uint32_t*)full_data)[NONCE_OFT];
			//pdata[NONCE_OFT] = endiandata[NONCE_OFT] + 1;
			goto out;
		}

		//}
		if ( __builtin_expect ( (uint64_t)throughput + (uint64_t)nonce_buf >= (uint64_t)max_nonce, 0) ) {

			break;
		}
		nonce_buf += throughput;

		/* Benchmark mode only. There are no pool jobs, so nothing ever sets work_restart, and the range
		 * test above compares this counter (which starts at 0) with the miner thread's absolute max_nonce,
		 * which includes a random start offset of up to ~4 billion. One scan call could therefore run for
		 * minutes to hours and --benchmark / --time-limit would never report. Bound each call to about
		 * one second instead, so the hashrate is measured and the time limit is honoured. */
		if (opt_benchmark && (nonce_buf & 0x3FF) == 0) {
			gettimeofday(&tv_now, NULL);
			if ((int64_t)(tv_now.tv_sec - tv_start.tv_sec) * 1000000 + (tv_now.tv_usec - tv_start.tv_usec) >= 1000000)
				break;
		}

	} while (!work_restart[thr_id].restart);


out:
	gettimeofday(&tv_end, NULL);

	pdata[NONCE_OFT] = ((uint32_t*)full_data)[NONCE_OFT] + 1;
	//free(data_key);

	return work->valid_nonces;
}

// cleanup
void free_verushash(int thr_id)
{
	if (!init[thr_id])
		return;



	init[thr_id] = false;
}
