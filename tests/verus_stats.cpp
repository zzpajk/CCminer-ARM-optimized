/* Statistics build (-DVERUS_X2 -DVERUS_STATS): what does the Verus clhash loop actually do?
 * Pure function of the data, so the numbers are the same on every CPU. Random key and input stand in for
 * the Haraka-generated key (which is pseudorandom). Prints the case mix, loop lengths, branch bias,
 * how predictable the next case is from the previous one, and how often key positions collide. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "verus_x2.h"
extern uint64_t verus_dbg_sel[2][32];
extern uint32_t verus_dbg_n;

static uint64_t rs = 0x2545F4914F6CDD1DULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static void fill(void *p, size_t n) { unsigned char *c = (unsigned char *)p; for (size_t i = 0; i < n; i++) c[i] = (unsigned char)rnd(); }

int main(int argc, char **argv)
{
	long N = argc > 1 ? atol(argv[1]) : 100000;
	alignas(64) __m128i key[560], kc[560];
	alignas(64) __m128i gp[2][32], gpx[2][32];
	uint16_t fr[2][32], fre[2][32];
	alignas(16) unsigned char b[2][64];
	uint64_t cs[8] = {0}, trans[8][8] = {{0}}, loops5[9] = {0}, loops6[9] = {0};
	uint64_t aes5 = 0, clm5 = 0, div6 = 0, clm6 = 0, same_pos = 0, rounds_total = 0, raw_dep = 0, dup_pos = 0;
	uint64_t distinct_sum = 0, lines_sum = 0, win_hit = 0, hashes = 0, div_per_hash_max = 0, div_total_hashes = 0;
	fill(key, sizeof(key)); memcpy(kc, key, sizeof(key));
	for (long it = 0; it < N; it += 2) {
		if ((it & 0x7f) == 0) { fill(key, sizeof(key)); memcpy(kc, key, sizeof(key)); }  /* new key every 64 pairs */
		fill(b[0], 64); fill(b[1], 64);
		uint64_t im[2];
		verus_dbg_n = 0;
		verusclhash_port2_2_x2(key, kc, b[0], b[1], 511, fr[0], fre[0], gp[0], gpx[0], fr[1], fre[1], gp[1], gpx[1], im);
		for (int l = 0; l < 2; l++) {
			__m128i *kk = l ? kc : key;   /* restore the key as the miner does after every nonce */
			for (int i = 31; i > -1; i--) { kk[fr[l][i]] = gp[l][i]; kk[fre[l][i]] = gpx[l][i]; }
		}
		for (int l = 0; l < 2; l++) {
			uint8_t seen[560] = {0}; uint8_t line[140] = {0};
			int distinct = 0, lines = 0, dv = 0;
			uint64_t prev = 99;
			for (int i = 0; i < 32; i++) {
				uint64_t sel = verus_dbg_sel[l][i];
				int c = (sel & 0x1c) >> 2;
				cs[c]++; rounds_total++;
				if (prev != 99) trans[prev][c]++;
				prev = c;
				if (c == 5 || c == 6) {
					int r = (int)(sel >> 61);              /* iterations = r + 1 */
					(c == 5 ? loops5 : loops6)[r + 1]++;
					for (int k = r; k >= 0; k--) {
						int bit = (sel & (0x10000000ULL << k)) != 0;
						if (c == 5) { if (bit) clm5++; else aes5++; }
						else { if (bit) { div6++; dv++; } else clm6++; }
					}
				}
				int pos[2] = { fr[l][i], fre[l][i] };
				if (pos[0] == pos[1]) same_pos++;
				for (int q = 0; q < 2; q++) {
					if (seen[pos[q]]) { dup_pos++; if (q == 0 || pos[0] != pos[1]) raw_dep++; }
					else { seen[pos[q]] = 1; distinct++; if (!line[pos[q] >> 2]) { line[pos[q] >> 2] = 1; lines++; } }
				}
			}
			distinct_sum += distinct; lines_sum += lines; hashes++;
			div_total_hashes += dv; if ((uint64_t)dv > div_per_hash_max) div_per_hash_max = dv;
			uint64_t w = im[l] & 511; int hit = 0;
			for (int p = 0; p < 560; p++) if (seen[p] && p >= (int)w && p < (int)w + 40) hit++;
			win_hit += hit;
		}
	}
	double H = 0, Hc = 0; uint64_t tt = 0;
	for (int c = 0; c < 8; c++) { double p = (double)cs[c] / rounds_total; if (p > 0) H -= p * log2(p); }
	for (int a = 0; a < 8; a++) { uint64_t ra = 0; for (int c = 0; c < 8; c++) ra += trans[a][c]; tt += ra;
		for (int c = 0; c < 8; c++) if (trans[a][c]) { double p = (double)trans[a][c] / ra; Hc -= ((double)ra) * p * log2(p); } }
	Hc /= tt;
	static const char *nm[8] = {"0x00","0x04","0x08","0x0c","0x10","0x14(loop aes/clmul)","0x18(loop clmul/DIV)","0x1c"};
	printf("verus_stats: %ld hashes, %lu rounds\n", (long)hashes, (unsigned long)rounds_total);
	for (int c = 0; c < 8; c++) printf("case %s: %.2f%%\n", nm[c], 100.0 * cs[c] / rounds_total);
	printf("case entropy %.3f bits (max 3), given previous case %.3f bits -> predictor gains %.3f bits\n", H, Hc, H - Hc);
	printf("0x14 loop iterations: ");
	for (int k = 1; k <= 8; k++) printf("%d:%lu ", k, (unsigned long)loops5[k]); printf("\n");
	printf("0x18 loop iterations: ");
	for (int k = 1; k <= 8; k++) printf("%d:%lu ", k, (unsigned long)loops6[k]); printf("\n");
	printf("0x14 inner branch: clmul %.1f%%  aes %.1f%%\n", 100.0 * clm5 / (clm5 + aes5), 100.0 * aes5 / (clm5 + aes5));
	printf("0x18 inner branch: DIVIDE %.1f%%  clmul %.1f%%\n", 100.0 * div6 / (div6 + clm6), 100.0 * clm6 / (div6 + clm6));
	printf("64-bit divides per hash: avg %.2f max %lu\n", (double)div_total_hashes / hashes, (unsigned long)div_per_hash_max);
	printf("key positions per hash: %.1f distinct of 64 touched; %.1f distinct 64-byte cache lines of 138; prand==prandex in %.2f%% of rounds\n",
		(double)distinct_sum / hashes, (double)lines_sum / hashes, 100.0 * same_pos / rounds_total);
	printf("re-touched positions per hash (read-after-write on key): %.2f\n", (double)dup_pos / hashes);
	printf("mutated positions inside the Haraka key window per hash: %.2f of 40\n", (double)win_hit / hashes);
	return 0;
}
