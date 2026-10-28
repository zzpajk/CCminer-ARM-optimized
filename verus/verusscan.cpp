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
        __m128i * __restrict data_key, const __m128i * __restrict pristine, uint16_t * __restrict fixrand, uint16_t * __restrict fixrandex,
        uint64_t (*clfn)(void *, const unsigned char *, uint64_t, uint16_t *, uint16_t *))
{
	memcpy(curBuf + 47, curBuf, 16);
	memcpy(curBuf + 63, curBuf, 1);
	memcpy(curBuf + 32, nonce, 15);
	uint64_t intermediate = clfn(data_key, curBuf, 511, fixrand, fixrandex);
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
 *   Mongoose M2 (0x53:0x001, slow divider): plain x2 best, sel2 -3..-4% (S8 sweep: sel +0.5% = noise)
 *   Mongoose M4 (0x53:0x003, S10): sel2 +3..4% over sel, +7..9% over x2 (both sweep rounds)
 *   Mongoose M5 (0x53:0x004, S20): sel2 +8..9% over x2;  Cortex-A76 (0x41:0xd0b): sel2 +4% over x2
 *   Mongoose M3 (0x53:0x002, S9): sel2 +4% over sel, +7% over x2 (both sweep rounds)
 *   Cortex-A75 (0x41:0xd0a, S10): x2, sel, sel2 equal within heat drift; gets the default sel2
 *   Cortex-A73 (0x41:0xd09, Galaxy A40): x2 best (bench x2 +12.5% vs sel2 +7.8% over plain; sweep round 1
 *   x2 > sel > sel2, round 2 a tie while throttling)
 * So Mongoose M1/M2 and Cortex-A73 use plain x2; every other out-of-order core uses sel2, plus (SEL bit 5) the
 * branch-free case 0x0c except on the A75: sweep 2026-10-28 vs sel2: M3 +2.0%, M5 +1.2..1.4%, M4 +0.9%,
 * A76 +0.4%, A78 +0.4%, X1 +0.1%, A75 -1.7%. (Bit 4, the light-case merge, lost 3..12% on every core.)
 * Branch-table dispatch (bit 6) vs that: A76 +2.2/+2.3% (both S20s), X1 +0.7%, A75/A78 +-0.1%, Mongoose
 * M2..M5 -2.7..-5.8%, so only the A76 uses it (SEL 99). All of them add bits 256 + 128, and ARM cores other
 * than A73/A76 also preload (512): see below. VERUS_SEL=0..3 in the environment
 * overrides the choice for all out-of-order cores (for testing); VERUS_SEL=7 adds the fully branch-free
 * case 0x14 (x2sel3). Bit 16 (light merge of cases 0/4/8/0x1c) and bit 32 (branch-free case 0x0c) are
 * selectable for testing: VERUS_SEL=16, 32, 48 (on top of x2) or 19, 35, 51 (on top of sel2). */
static int verus_sel_for_cpu(int cpu)
{
	int sel = VERUS_SEL_DEFAULT;
#ifdef VERUS_PERCORE
	if (cpu >= 0 && cpu < 1024) {
		if (g_impl[cpu] == 0x53) sel = (g_part[cpu] == 0x001) ? 0 : 35;
		else if (g_impl[cpu] == 0x41 && g_part[cpu] == 0xd09) sel = 0;   /* Cortex-A73 */
		else if (g_impl[cpu] == 0x41 && g_part[cpu] == 0xd0a) sel = 3;   /* Cortex-A75: selc -1.7% (S10 sweep) */
		else if (g_impl[cpu] == 0x41 && g_part[cpu] == 0xd0b) sel = 99;  /* Cortex-A76: + branch-table dispatch */
		else sel = 35;                                                   /* sel2 + branch-free case 0x0c */
		/* every core: both Haraka512 interleaved (256) + journal-free key restore (128). Sweep 2026-10-28 vs
		 * the paths above: A76 +4.2%, M3 +3.6%, X1 +3.4%, M5 +2.7/+3.2%, M4 +2.7%, A78 +1.9%, M2 +1.8%,
		 * A75 +1.5%. (128 is dropped below when the build has no pristine key copy.) */
		sel |= 256 | 128;
		/* ARM-designed out-of-order cores except A73/A76: also preload (512), on sel2+selc. Sweep vs 419:
		 * A75 +3.2% (931 vs its 387: better too), A78 +1.8%, X1 +1.3%; Mongoose M3/M4/M5 -1..-3%, so not there. */
		if (g_impl[cpu] == 0x41 && g_part[cpu] != 0xd09 && g_part[cpu] != 0xd0b) sel = 931;
		/* Qualcomm Kryo Gold cores report implementer 0x51 but are Cortex derivatives: use the path of the
		 * Cortex core they are built on. NOT measured yet (no such phone tested): 0x800 Kryo 280 Gold (A73,
		 * SD835), 0x802 Kryo 385 Gold (A75, SD845 / 7xx), 0x804 Kryo 485 Gold (A76, SD855 / 7xx). */
		if (g_impl[cpu] == 0x51) {
			if (g_part[cpu] == 0x800) sel = 384;
			else if (g_part[cpu] == 0x802) sel = 931;
			else if (g_part[cpu] == 0x804) sel = 483;
		}
	}
#ifdef VERUS_PERCORE3
	sel |= 4;   /* x2percore3: also the fully branch-free case 0x14 on every out-of-order core */
#endif
	static int env = -2;
	if (env == -2) { const char *e = getenv("VERUS_SEL"); env = -1;
		if (e && e[0]) { char *end; long x = strtol(e, &end, 10); if (!*end && (x == 0 || x == 1 || x == 2 || x == 3 || x == 4 || x == 5 || x == 7 || x == 8 || x == 9 || x == 11 || x == 16 || x == 32 || x == 48 || x == 19 || x == 35 || x == 51 || x == 64 || x == 67 || x == 99 || x == 39 || x == 128 || x == 131 || x == 163 || x == 227 || x == 256 || x == 259 || x == 291 || x == 355 || x == 384 || x == 387 || x == 419 || x == 483 || x == 512 || x == 515 || x == 547 || x == 640 || x == 643 || x == 675 || x == 768 || x == 771 || x == 803 || x == 896 || x == 899 || x == 931)) env = (int)x; } }
	if (env >= 0) sel = env;
#ifndef VERUS_PRISTINE
	sel &= ~128;   /* the journal-free two-nonce restore needs the pristine key copy */
#endif
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
		lanes == 1 ? "" : (*sel >= 512 ? ", +preload" : *sel >= 128 ? ((*sel & 256) ? ((*sel & 128) ? ", +haraka2+pristine" : ", +haraka2") : ", +pristine") : *sel == 39 ? ", sel3+selc" : *sel == 99 ? ", sel2+selc+bt" : *sel == 67 ? ", sel2+bt" : *sel == 64 ? ", bt" : *sel == 51 ? ", sel2+light+selc" : *sel == 35 ? ", sel2+selc" : *sel == 19 ? ", sel2+light" : *sel == 48 ? ", light+selc" : *sel == 32 ? ", selc" : *sel == 16 ? ", light" : *sel == 11 ? ", fuse+sel2" : *sel == 9 ? ", fuse+sel" : *sel == 8 ? ", fuse" : *sel == 7 ? ", sel3" : *sel == 5 ? ", sel14+full14" : *sel == 4 ? ", full14" : *sel == 3 ? ", sel2" : *sel == 1 ? ", sel" : *sel == 2 ? ", sel18" : "")); }
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
	uint8_t *blockhash_half; struct timeval tv_start; const __m128i *pristine;
};

/* variants x2/x3/x4/auto: VERUS_LANES nonces per iteration, each lane with its own key copy (see verus_x2.h). */
template<int SEL, int NLT = VERUS_LANES>
static __attribute__((noinline)) void verus_scan_lanes(struct verus_scan_ctx *c)
{
	struct work *work = c->work;
	uint32_t nonce_buf = c->nonce_buf;
	const uint32_t Htarg = c->Htarg;
	uint8_t *nonceSpace = c->nonceSpace;
	struct timeval tv_now;
	const int NL = NLT;
	constexpr int NX = NLT > 1 ? NLT - 1 : 1;   /* extra lanes (at least 1 so the arrays are valid) */
	alignas(64) __m128i keyL[NX][VERUS_KEY_SIZE128 + 8];
	alignas(64) __m128i gpL[NX][32], gpxL[NX][32];
	alignas(16) uint8_t halfL[NX][64];
	uint16_t fixrandL[NX][32], fixrandexL[NX][32];
	struct verus_lane L[NLT];
	L[0] = (struct verus_lane){ c->data_key, c->fixrand, c->fixrandex, c->gp, c->gpx, c->blockhash_half, c->pristine };
	for (int l = 1; l < NL; l++) {
		memcpy(keyL[l - 1], c->data_key, VERUS_KEY_SIZE128 * sizeof(__m128i));
		memcpy(halfL[l - 1], c->blockhash_half, 64);
		L[l] = (struct verus_lane){ keyL[l - 1], fixrandL[l - 1], fixrandexL[l - 1], gpL[l - 1], gpxL[l - 1], halfL[l - 1], c->pristine };
	}
	uint8_t nonceL[NLT][15];
	uint32_t vh[NLT][8];
	unsigned char *hp[NLT]; const unsigned char *np[NLT];
	for (int l = 0; l < NL; l++) { hp[l] = (unsigned char *)vh[l]; np[l] = nonceL[l]; }
	throughput = NL;
	do {
		*c->hashes_done = nonce_buf + throughput;
		for (int l = 0; l < NL; l++) {
			memcpy(nonceL[l], nonceSpace, 15);
			((uint32_t *)(&nonceL[l][11]))[0] = nonce_buf + l;
		}
		memset(vh, 0, sizeof(vh));

		Verus2hash_xN<NLT, (NLT <= 2 ? SEL : 0)>(hp, L, np);

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
#ifdef VERUS_PRISTINE
	/* testing aid: VERUS_PRE1=1 runs the single-nonce loop with its four common operands loaded before the
	 * case jump ("preload") */
	static int pre1 = -1;
	if (pre1 < 0) { const char *e = getenv("VERUS_PRE1"); pre1 = (e && e[0] == '1' && !e[1]) ? 1 : 0; }
	uint64_t (*clfn)(void *, const unsigned char *, uint64_t, uint16_t *, uint16_t *) =
		pre1 ? verusclhash_port2_2_nojournal_pre : verusclhash_port2_2_nojournal;
#endif
#ifdef VERUS_X2
	int sel = 0;
	if (verus_lanes_for_this_core(thr_id, &sel) > 1)
	{
		/* The multi-nonce loop lives in its own noinline function so that this function (and the plain loop
		 * below, which is the baseline code) is compiled exactly as in the baseline build. */
		struct verus_scan_ctx c = { work, thr_id, max_nonce, hashes_done, nonce_buf, nonceSpace, full_data, sol_data,
			Htarg, vhash, data_key, fixrand, fixrandex, data_key_prand, data_key_prandex, blockhash_half, tv_start,
#ifdef VERUS_PRISTINE
			pristine_key
#else
			NULL
#endif
			};
		switch (sel) {
		case 931: verus_scan_lanes<931>(&c); break;
		case 899: verus_scan_lanes<899>(&c); break;
		case 896: verus_scan_lanes<896>(&c); break;
		case 803: verus_scan_lanes<803>(&c); break;
		case 771: verus_scan_lanes<771>(&c); break;
		case 768: verus_scan_lanes<768>(&c); break;
		case 675: verus_scan_lanes<675>(&c); break;
		case 643: verus_scan_lanes<643>(&c); break;
		case 640: verus_scan_lanes<640>(&c); break;
		case 547: verus_scan_lanes<547>(&c); break;
		case 515: verus_scan_lanes<515>(&c); break;
		case 512: verus_scan_lanes<512>(&c); break;
		case 483: verus_scan_lanes<483>(&c); break;
		case 419: verus_scan_lanes<419>(&c); break;
		case 387: verus_scan_lanes<387>(&c); break;
		case 384: verus_scan_lanes<384>(&c); break;
		case 355: verus_scan_lanes<355>(&c); break;
		case 291: verus_scan_lanes<291>(&c); break;
		case 259: verus_scan_lanes<259>(&c); break;
		case 256: verus_scan_lanes<256>(&c); break;
		case 227: verus_scan_lanes<227>(&c); break;
		case 163: verus_scan_lanes<163>(&c); break;
		case 131: verus_scan_lanes<131>(&c); break;
		case 128: verus_scan_lanes<128>(&c); break;
		case 39: verus_scan_lanes<39>(&c); break;
		case 99: verus_scan_lanes<99>(&c); break;
		case 67: verus_scan_lanes<67>(&c); break;
		case 64: verus_scan_lanes<64>(&c); break;
		case 51: verus_scan_lanes<51>(&c); break;
		case 35: verus_scan_lanes<35>(&c); break;
		case 19: verus_scan_lanes<19>(&c); break;
		case 48: verus_scan_lanes<48>(&c); break;
		case 32: verus_scan_lanes<32>(&c); break;
		case 16: verus_scan_lanes<16>(&c); break;
		case 11: verus_scan_lanes<11>(&c); break;
		case 9:  verus_scan_lanes<9>(&c); break;
		case 8:  verus_scan_lanes<8>(&c); break;
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
#ifdef VERUS_PRISTINE
	{
		/* testing aid: VERUS_SEL1=N runs single-nonce cores through the two-nonce round code with one lane
		 * and SEL N (128 = journal-free, i.e. the same algorithm as the default single-nonce loop) */
		static int sel1 = -2;
		if (sel1 == -2) { const char *e = getenv("VERUS_SEL1"); sel1 = -1; if (e && e[0]) { char *end; long x = strtol(e, &end, 10);
			if (!*end && (x == 128 || x == 129 || x == 130 || x == 131 || x == 160 || x == 163 || x == 192 || x == 224 || x == 640 || x == 672)) sel1 = (int)x; } }
		if (sel1 >= 0) {
			struct verus_scan_ctx c = { work, thr_id, max_nonce, hashes_done, nonce_buf, nonceSpace, full_data, sol_data,
				Htarg, vhash, data_key, fixrand, fixrandex, data_key_prand, data_key_prandex, blockhash_half, tv_start, pristine_key };
			switch (sel1) {
			case 129: verus_scan_lanes<129, 1>(&c); break;
			case 130: verus_scan_lanes<130, 1>(&c); break;
			case 131: verus_scan_lanes<131, 1>(&c); break;
			case 160: verus_scan_lanes<160, 1>(&c); break;
			case 163: verus_scan_lanes<163, 1>(&c); break;
			case 192: verus_scan_lanes<192, 1>(&c); break;
			case 224: verus_scan_lanes<224, 1>(&c); break;
			case 640: verus_scan_lanes<640, 1>(&c); break;
			case 672: verus_scan_lanes<672, 1>(&c); break;
			default:  verus_scan_lanes<128, 1>(&c); break;
			}
			goto out;
		}
	}
#endif
#endif
	do {

		*hashes_done = nonce_buf + throughput;
				((uint32_t *)(&nonceSpace[11]))[0] = nonce_buf;

		((uint32_t *)(&nonceSpace[11]))[0] = nonce_buf;

#ifdef VERUS_PRISTINE
		Verus2hash_pristine((unsigned char *)vhash, (unsigned char *)blockhash_half, nonceSpace, data_key,
				pristine_key, fixrand, fixrandex, clfn);
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
