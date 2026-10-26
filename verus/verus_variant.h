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

#define VERUS_VARIANT_NAME_RAW "baseline" VERUS_VAR_ZIPMIX
/* "baseline+zipmix" reads oddly, so strip the "baseline" prefix when any
 * variant flag is set. */
#ifdef VERUS_ZIPMIX
#  define VERUS_VARIANT_NAME (VERUS_VARIANT_NAME_RAW + 9)
#else
#  define VERUS_VARIANT_NAME VERUS_VARIANT_NAME_RAW
#endif

#endif /* VERUS_VARIANT_H */
