#!/usr/bin/env python3
"""
check_filelists.py -- L0 guard: verif/formal/rv32sky/checks.cfg reads exactly
rtl/files.f, in the same order.

checks.cfg's [script-sources] carries the RTL list a second time, on one
read_slang line, because riscv-formal's -F would resolve files.f's
repo-root-relative paths one directory too deep (checks.cfg comment). Nothing
enforced the match: the fourth duplicated source list in this project
(PROJECT_CONTEXT standing risks). This is the enforcement. M3.7,
docs/results/0030.

rtl/files.f is parsed by tools/gen_cov_vlt.py's own reader, so there is one
parser of that file, not two.

EXIT  0 lists match; 1 mismatch; 2 setup error.
"""

import importlib.util
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CFG = REPO / "verif/formal/rv32sky/checks.cfg"
PREFIX = "@basedir@/cores/@core@/"


def setup_error(msg):
    print(f"check_filelists: SETUP ERROR: {msg}")
    sys.exit(2)


def slang_files():
    if not CFG.is_file():
        setup_error(f"{CFG.relative_to(REPO)} not found")
    section, hits = None, []
    for ln, raw in enumerate(CFG.read_text().splitlines(), 1):
        s = raw.strip()
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
            continue
        if section == "script-sources" and s.startswith("read_slang"):
            hits.append((ln, s.split()))
    if len(hits) != 1:
        setup_error(f"expected exactly one read_slang line in [script-sources], found {len(hits)}")
    ln, toks = hits[0]
    files, bad = [], []
    for t in toks[1:]:
        if t.endswith((".sv", ".v", ".svh", ".vh")):
            if not t.startswith(PREFIX):
                bad.append(t)
            else:
                files.append(t[len(PREFIX):])
    if bad:
        setup_error(f"checks.cfg:{ln}: source(s) without the {PREFIX} prefix: {bad}")
    if not files:
        setup_error(f"checks.cfg:{ln}: read_slang names no source files")
    return ln, files


def main():
    spec = importlib.util.spec_from_file_location("gen_cov_vlt", REPO / "tools/gen_cov_vlt.py")
    gcv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gcv)
    try:
        want = gcv.rtl_files(REPO)
    except gcv.Refuse as e:
        setup_error(str(e))
    ln, got = slang_files()

    print(f"check_filelists: rtl/files.f {len(want)} file(s), checks.cfg:{ln} {len(got)} file(s)")
    if got == want:
        print("check_filelists: PASS (same files, same order)")
        return
    for i in range(max(len(want), len(got))):
        w = want[i] if i < len(want) else "-"
        g = got[i] if i < len(got) else "-"
        print(f"  {'  ' if w == g else '!='} {i + 1:>2}  files.f {w:<28} checks.cfg {g}")
    only_f = sorted(set(want) - set(got))
    only_c = sorted(set(got) - set(want))
    if only_f:
        print(f"  only in rtl/files.f: {only_f}")
    if only_c:
        print(f"  only in checks.cfg:  {only_c}")
    if not only_f and not only_c:
        print("  same files, different ORDER (slang resolves the package first; order matters)")
    print("check_filelists: FAIL")
    sys.exit(1)


if __name__ == "__main__":
    main()
