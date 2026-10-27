#!/usr/bin/env python3
"""Count AES round instructions that the CPU can fuse.

Cortex-A53/A55/A7x and Mongoose fuse AESE with a directly following AESMC on the same register
(and AESD/AESIMC), so a round costs one slot instead of two. Interleaving work (two lanes, LTO,
scheduling) can pull the pair apart. Reads `objdump -d --no-show-raw-insn` output on stdin and
reports, per function containing AES instructions: aese total, fused pairs (next instruction is
aesmc with the same destination register), split pairs.
Usage: objdump -d --no-show-raw-insn ccminer | python3 aes_pairs.py [name-filter ...]
"""
import re, sys

func = None
stats = {}
prev = None
filters = sys.argv[1:]
fn_re = re.compile(r'^[0-9a-f]+ <(.+)>:$')
ins_re = re.compile(r'^\s*[0-9a-f]+:\s+(\S+)\s*(.*)$')
for line in sys.stdin:
    line = line.rstrip('\n')
    m = fn_re.match(line)
    if m:
        func, prev = m.group(1), None
        continue
    m = ins_re.match(line)
    if not m or func is None:
        continue
    op, args = m.group(1), m.group(2)
    if prev is not None:
        pop, pargs = prev
        if pop in ('aese', 'aesd'):
            s = stats.setdefault(func, [0, 0, 0])
            s[0] += 1
            want = 'aesmc' if pop == 'aese' else 'aesimc'
            dst = pargs.split(',')[0].strip()
            if op == want and args.split(',')[0].strip() == dst and args.split(',')[1].strip() == dst:
                s[1] += 1
            else:
                s[2] += 1
    prev = (op, args)

tot = [0, 0, 0]
for f, (n, fused, split) in sorted(stats.items(), key=lambda kv: -kv[1][0]):
    if filters and not any(x in f for x in filters):
        continue
    tot = [a + b for a, b in zip(tot, (n, fused, split))]
    print(f"{f[:60]:60s} aese/aesd={n:5d} fused={fused:5d} split={split:5d}")
print(f"TOTAL aese/aesd={tot[0]} fused={tot[1]} split={tot[2]}")
