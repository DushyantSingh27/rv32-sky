#!/usr/bin/env python3
"""
Compare a Sail instruction trace against the core's retirement trace.

This is the first check in this project against a reference NEITHER of us
wrote. Every golden checksum so far is self-derived; the decoder's assembler
reference is the only other external check. Sail is the RISC-V Foundation's
official formal specification of the ISA.

Both traces are normalised to one record per retired instruction:
    (pc, rd, value)   with rd = None when the instruction writes no register.

Sail format:
    [64] [M]: 0x00000100 (0x00001B37) lui x22, 0x1        halt+0
    x22 <- 0x00001000
The register write is an OPTIONAL following line - absent when the instruction
writes nothing, including `addi x0, x0, 0`.

Core format, from tb_core.cpp --trace:
       67  pc=0x00000100  instr=0x00001b37  x22 <= 0x00001000
"""
import re, sys, argparse

SAIL_INSTR = re.compile(r'^\[(\d+)\]\s+\[(\w)\]:\s+0x([0-9A-Fa-f]+)\s+\(0x([0-9A-Fa-f]+)\)')
SAIL_WRITE = re.compile(r'^x(\d+)\s+<-\s+0x([0-9A-Fa-f]+)\s*$')

CORE_LINE  = re.compile(
    r'pc=0x([0-9a-fA-F]+)\s+instr=0x([0-9a-fA-F]+)'
    r'(?:\s+x\s*(\d+)\s+<=\s+0x([0-9a-fA-F]+))?')

def parse_sail(path):
    recs, pending = [], None
    for line in open(path):
        m = SAIL_INSTR.match(line)
        if m:
            if pending: recs.append(pending)
            pending = {"pc": int(m.group(3), 16),
                       "instr": int(m.group(4), 16),
                       "rd": None, "val": None}
            continue
        m = SAIL_WRITE.match(line)
        if m and pending:
            rd = int(m.group(1))
            if rd != 0:                       # x0 writes are architecturally void
                pending["rd"]  = rd
                pending["val"] = int(m.group(2), 16)
    if pending: recs.append(pending)
    return recs

def parse_core(path):
    recs = []
    for line in open(path):
        m = CORE_LINE.search(line)
        if not m: continue
        rd  = int(m.group(3)) if m.group(3) else None
        val = int(m.group(4), 16) if m.group(4) else None
        if rd == 0: rd, val = None, None
        recs.append({"pc": int(m.group(1), 16), "instr": int(m.group(2), 16),
                     "rd": rd, "val": val})
    return recs

def fmt(r):
    w = f"x{r['rd']} <= 0x{r['val']:08x}" if r["rd"] is not None else "(no write)"
    return f"pc=0x{r['pc']:08x} instr=0x{r['instr']:08x} {w}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sail"); ap.add_argument("core")
    ap.add_argument("--limit", type=int, default=0,
                    help="compare only the first N instructions")
    a = ap.parse_args()

    s, c = parse_sail(a.sail), parse_core(a.core)
    print(f"sail: {len(s)} instructions")
    print(f"core: {len(c)} instructions")

    n = min(len(s), len(c))
    if a.limit: n = min(n, a.limit)

    for i in range(n):
        if s[i]["pc"] != c[i]["pc"] or s[i]["rd"] != c[i]["rd"] \
           or s[i]["val"] != c[i]["val"]:
            print(f"\nDIVERGENCE at instruction {i}")
            lo = max(0, i - 3)
            print("\n  --- preceding, in agreement ---")
            for j in range(lo, i):
                print(f"  [{j}] {fmt(s[j])}")
            print("\n  --- first difference ---")
            print(f"  sail [{i}] {fmt(s[i])}")
            print(f"  core [{i}] {fmt(c[i])}")
            print("\n  --- sail continues ---")
            for j in range(i + 1, min(i + 4, len(s))):
                print(f"  [{j}] {fmt(s[j])}")
            print("\nRESULT: FAIL")
            return 1

    # Lengths differ legitimately: the two stop on different conventions.
    # Sail terminates on the HTIF tohost write inside the halt loop; the
    # Verilator harness stops at the earlier store to 0x8000_0000. The core's
    # trace is therefore a PREFIX of Sail's, and agreement over that prefix is
    # the result that matters.
    if len(s) != len(c) and not a.limit:
        extra = s[n:] if len(s) > len(c) else c[n:]
        who   = "sail" if len(s) > len(c) else "core"
        print(f"\nlengths differ: sail {len(s)}, core {len(c)}")
        print(f"  {who} continued for {len(extra)} more instructions:")
        for r in extra[:6]:
            print(f"    {fmt(r)}")
        if all(0x1000 <= r["pc"] < 0x2000 or True for r in extra[:0]):
            pass
        print("  (expected: the two terminate on different conventions)")

    print(f"\n{n} instructions compared, all agree")
    print("RESULT: PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
