/*
 * Named build variants for Verushash benchmarking.
 *
 * Each variant is selected at compile time with one -D flag and reports its
 * name in the miner banner, so a benchmark report always says which code it
 * measured. With no flag the hashing code is the original ("baseline").
 *
 * Every variant, baseline included, carries the same benchmark-mode fix in
 * verus/verusscan.cpp (active only with --benchmark): upstream's scan loop never
 * returned in benchmark mode, so --benchmark and --time-limit printed nothing.
 *
 *   baseline   original code, no flag
 *   zipmix     Haraka512 lane-mixing (MIX4A/MIX4B/MIX4_LAST) done as the
 *              reference unpack/zip network (8 single-cycle ZIPs, depth 2)
 *              instead of chains of dependent lane inserts
 *
 *   x2         VERUS_X2      two nonces hashed in lockstep, each with its own key copy, so an
 *                            out-of-order core can overlap the two dependency chains
 *
 *   x2fuse     VERUS_X2 VERUS_FUSE  two lanes with one 64-way jump on the pair of cases per round;
 *                            straight-line pairs run interleaved in one block (tools/gen_fuse.py)
 *
 *   x2sel      VERUS_X2 VERUS_SEL14  x2 where the inner aes/clmul choice of case 0x14 is made with a
 *                            select instead of a branch (two-nonce path only)
 *
 *   x2sel2     x2sel plus the same for case 0x18 (divide/clmul), at the price of a divide per iteration
 *
 *   x2percore  VERUS_X2 VERUS_AUTO VERUS_PERCORE  per core at run time: plain loop on in-order cores,
 *                            x2 on Mongoose M1/M2, x2sel2 on M5 and ARM big cores, x2sel on other
 *                            Mongoose; VERUS_SEL=0..3 overrides for testing
 *
 *   x2sel3     VERUS_X2 VERUS_SEL3   x2sel2 plus case 0x14 with no branch at all (8 masked steps)
 *
 *   x2percore3 x2percore plus the fully branch-free case 0x14 on every out-of-order core
 *
 * Variants are combined by defining more than one flag; the name then lists
 * them joined with '+'.
 */
#ifndef VERUS_VARIANT_H
#define VERUS_VARIANT_H

#ifdef VERUS_ZIPMIX
#  define VERUS_VAR_ZIPMIX "+zipmix"
#else
#  define VERUS_VAR_ZIPMIX ""
#endif

#ifdef VERUS_X2
#  ifndef VERUS_LANES
#    define VERUS_LANES 2
#  endif
#  if VERUS_LANES == 2
#    define VERUS_VAR_LANES "+x2"
#  elif VERUS_LANES == 3
#    define VERUS_VAR_LANES "+x3"
#  else
#    define VERUS_VAR_LANES "+x4"
#  endif
#  if defined(VERUS_PERCORE) && defined(VERUS_PERCORE3)
#    define VERUS_VAR_FUSE "percore3"
#  elif defined(VERUS_PERCORE)
#    define VERUS_VAR_FUSE "percore"
#  elif defined(VERUS_FUSE)
#    define VERUS_VAR_FUSE "fuse"
#  elif defined(VERUS_SEL3)
#    define VERUS_VAR_FUSE "sel3"
#  elif defined(VERUS_SEL14) && defined(VERUS_SEL18)
#    define VERUS_VAR_FUSE "sel2"
#  elif defined(VERUS_SEL14)
#    define VERUS_VAR_FUSE "sel"
#  else
#    define VERUS_VAR_FUSE ""
#  endif
#  if defined(VERUS_AUTO) && !defined(VERUS_PERCORE)
#    define VERUS_VAR_X2 VERUS_VAR_LANES VERUS_VAR_FUSE "auto"
#  else
#    define VERUS_VAR_X2 VERUS_VAR_LANES VERUS_VAR_FUSE
#  endif
#else
#  define VERUS_VAR_X2 ""
#endif

#define VERUS_VARIANT_NAME_RAW "baseline" VERUS_VAR_ZIPMIX VERUS_VAR_X2
/* "baseline+zipmix" reads oddly, so strip the "baseline" prefix when any
 * variant flag is set. */
#if defined(VERUS_ZIPMIX) || defined(VERUS_X2)
#  define VERUS_VARIANT_NAME (VERUS_VARIANT_NAME_RAW + 9)
#else
#  define VERUS_VARIANT_NAME VERUS_VARIANT_NAME_RAW
#endif

#endif /* VERUS_VARIANT_H */
