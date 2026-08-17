#!/usr/bin/env python3
"""Regenerate a NOP-free variant of a padded test program."""
import pathlib, sys
if len(sys.argv) != 3:
    sys.exit("usage: strip_nops.py in.S out.S")
src = pathlib.Path(sys.argv[1]).read_text()
out = [l for l in src.splitlines(keepends=True) if l.strip() != "nop"]
pathlib.Path(sys.argv[2]).write_text("".join(out))
print(f"{sys.argv[2]}: {len(src.splitlines()) - len(out)} NOPs removed")
