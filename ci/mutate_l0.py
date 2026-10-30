#!/usr/bin/env python3
"""
mutate_l0.py -- show that every L0 check can fail (PROJECT_INSTRUCTIONS 4.5).

For the baseline and for each mutant: a FRESH copy of the working tree (tracked
plus untracked-but-not-ignored files, so build products never travel), its
edits applied with exact-count assertions, then ci/l0.sh run inside the copy.
The user's tree is never edited. Each copy is deleted after its run unless
--keep is given (the copies carry the 33 MB ACT4 ELF set).

Edits are (path, old, new, count). old=None selects a non-text edit:
  new == DELETE              remove the file
  new is bytes               append those bytes (binary-safe)
  new == (COPY_FROM, src)    create path as a copy of src

  baseline  must exit 0
  mutant    must exit non-zero AND its expected check must be FAIL in the
            L0 summary. Other checks failing too is recorded, not an error.

A mutant whose edit does not apply is an ERROR, never a pass: a .replace()
that changes nothing is failure mode #2.

Usage:  python3 ci/mutate_l0.py [--keep]     (run from anywhere)
Exit:   0 baseline passed and every mutant was caught; 1 otherwise.
"""

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
END = "endmodule\n"
DELETE = "DELETE"
COPY_FROM = "COPY_FROM"
ELF = "verif/compliance/rv32sky/elfs/rv32i/I/I-add-00.elf"
RUNC = "verif/compliance/rv32sky/run_compliance.sh"

# (id, expected check, what it models, [(file, old, new, count), ...], extra env)
MUTANTS = [
    ("P1", "pragmas", "coverage_off hidden in a comment",
     [("rtl/core/alu.sv", END, "  /* verilator coverage_off */\n" + END, 1)], None),
    ("P2", "pragmas", "translate_off: simulation and synthesis differ",
     [("rtl/core/alu.sv", END, "  // synthesis translate_off\n  // synthesis translate_on\n" + END, 1)], None),
    ("P3", "pragmas", "lint waiver not in the allowlist",
     [("rtl/core/alu.sv", END, "  /* verilator lint_off WIDTH */\n  /* verilator lint_on WIDTH */\n" + END, 1)], None),
    ("P4", "pragmas", "allowlist row goes stale (waiver pair removed from RTL)",
     [("rtl/core/muldiv.sv", "  /* verilator lint_off SYNCASYNCNET */\n", "", 1),
      ("rtl/core/muldiv.sv", "  /* verilator lint_on SYNCASYNCNET */\n", "", 1)], None),
    ("P5", "pragmas", "sim_only waiver now covers synthesised lines",
     [("rtl/core/muldiv.sv", "`ifndef SYNTHESIS\n  // Immediate assertions only",
       "  // Immediate assertions only", 1),
      ("rtl/core/muldiv.sv", "  /* verilator lint_on SYNCASYNCNET */\n`endif\n",
       "  /* verilator lint_on SYNCASYNCNET */\n", 1)], None),
    ("P6", "pragmas", "lint_off with no lint_on (waives to end of file)",
     [("rtl/core/if_stage.sv", "  /* verilator lint_on SYNCASYNCNET */\n", "", 1)], None),
    ("P7", "pragmas", "second waiver pair beyond the allowlisted count",
     [("rtl/pkg/rv32_pkg.sv", "endpackage\n/* verilator lint_on UNUSEDPARAM */\n",
     "endpackage\n/* verilator lint_on UNUSEDPARAM */\n"
     "/* verilator lint_off UNUSEDPARAM */\n/* verilator lint_on UNUSEDPARAM */\n", 1)], None),
    ("P8", "pragmas", "directive on the second line of a block comment",
     [("rtl/core/alu.sv", END, "  /*\n     verilator coverage_off\n  */\n" + END, 1)], None),
    ("F1", "filelists", "checks.cfg order differs from rtl/files.f",
     [("verif/formal/rv32sky/checks.cfg",
     "rtl/core/alu.sv @basedir@/cores/@core@/rtl/core/regfile.sv",
     "rtl/core/regfile.sv @basedir@/cores/@core@/rtl/core/alu.sv", 1)], None),
    ("F2", "filelists", "checks.cfg drops a file",
     [("verif/formal/rv32sky/checks.cfg", " @basedir@/cores/@core@/rtl/mem/tcm.sv", "", 1)], None),
    ("F3", "filelists", "rtl/files.f gains a file checks.cfg lacks",
     [("rtl/files.f", "rtl/core/csr.sv\n", "rtl/core/csr.sv\nrtl/core/muldiv.sv\n", 1)], None),
    # The signal name must NOT contain "unused": Verilator's --unused-regexp
    # defaults to "*unused*" and exempts such names from UNUSED warnings. The
    # first version of this mutant was named mut_unused_q and passed lint --
    # failure mode #1, the test value landing where both answers agree.
    ("L1", "lint", "dangling signal, undriven and unread (-Wall)",
     [("rtl/core/alu.sv", END, "  logic mut_dangling_q;\n" + END, 1)], None),
    ("C1", "covvlt-emit", "conditional on an unknown macro",
     [("rtl/core/alu.sv", END, "`ifdef MUT_UNKNOWN\n`endif\n" + END, 1)], None),
    ("C2", "covvlt-selftest", "exclusion-rule tool loses RISCV_FORMAL",
     [("tools/gen_cov_vlt.py", 'KNOWN = ("SYNTHESIS", "RISCV_FORMAL")', 'KNOWN = ("SYNTHESIS",)', 1)], None),
    ("G1", "guard", "a different Verilator build is named",
     [], "fake_verilator"),
    ("P9", "pragmas", "attribute (* keep *): synthesis differs from simulation",
     [("rtl/core/alu.sv", END, "  (* keep *) logic mut_attr_q;\n" + END, 1)], None),
    ("S1", "pragmas-selftest", "attribute pattern mistakes @(*) for an attribute",
     [("ci/check_pragmas.py", r'ATTR = re.compile(r"\(\*(?!\s*\))")', r'ATTR = re.compile(r"\(\*")', 1)], None),
    ("E1", "elfs", "one committed ELF corrupted",
     [(ELF, None, b"\x00", 0)], None),
    ("E2", "elfs", "one committed ELF deleted",
     [(ELF, None, DELETE, 0)], None),
    ("E3", "elfs", "an ELF the manifest does not list",
     [("verif/compliance/rv32sky/elfs/rv32i/I/I-mutant-00.elf", None, (COPY_FROM, ELF), 0)], None),
    ("E4", "elfs", "ACT4 config edited after export (stale ELFs)",
     [("verif/compliance/rv32sky/link.ld", None, b"/* drift */\n", 0)], None),
    ("E5", "elfs", "EXPECT_TOTAL changed without re-export",
     [(RUNC, "EXPECT_TOTAL=47\n", "EXPECT_TOTAL=48\n", 1)], None),
    ("E6", "elfs", "exclusion list changed without re-export (InterruptsSm re-enabled)",
     [(RUNC, 'EXCLUDE="Sm,SdtrigSm,SdtrigS,SdtrigU,InterruptsSm"', 'EXCLUDE="Sm,SdtrigSm,SdtrigS,SdtrigU"', 1)], None),
]

FAKE = """#!/bin/sh
echo "Verilator 5.053 2026-08-01 rev v5.053"
"""


def snapshot(dst):
    """Copy tracked + untracked-not-ignored files of the working tree."""
    out = subprocess.run(["git", "-C", str(REPO), "ls-files", "-co", "--exclude-standard", "-z"],
                         check=True, capture_output=True).stdout.decode()
    n = 0
    for rel in filter(None, out.split("\0")):
        src = REPO / rel
        if not src.is_file():          # deleted in the working tree
            continue
        d = dst / rel
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, d)
        n += 1
    if n == 0:
        raise SystemExit("mutate_l0: snapshot copied no files")
    return n


def apply(root, path, old, new, count):
    p = root / path
    if old is None:
        if new == DELETE:
            if not p.is_file():
                return "file to delete does not exist"
            p.unlink()
            return None if not p.exists() else "file still exists"
        if isinstance(new, bytes):
            if not p.is_file():
                return "file to append to does not exist"
            before = p.read_bytes()
            p.write_bytes(before + new)
            return None if p.read_bytes() != before else "append changed nothing"
        if isinstance(new, tuple) and new[0] == COPY_FROM:
            if p.exists():
                return "copy target already exists"
            shutil.copyfile(root / new[1], p)
            return None if p.is_file() else "copy not created"
        return f"unknown non-text edit {new!r}"
    text = p.read_text()
    found = text.count(old)
    if found != count:
        return f"anchor found {found} time(s), want {count}: {old!r}"
    p.write_text(text.replace(old, new))
    if p.read_text() == text:
        return "edit changed nothing"
    return None


def run_l0(root, env_extra):
    env = dict(os.environ)
    env.update(env_extra)
    r = subprocess.run(["bash", str(root / "ci/l0.sh")], cwd=root, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    summary = r.stdout.split("==================== L0 SUMMARY", 1)
    fails = re.findall(r"^  \[FAIL\] (\S+)", summary[1], re.M) if len(summary) == 2 else ["NO-SUMMARY"]
    return r.returncode, fails, r.stdout


def main():
    keep = "--keep" in sys.argv
    work = pathlib.Path(tempfile.mkdtemp(prefix="mutate_l0_"))
    print(f"mutate_l0: work dir {work}")
    rows, ok_all = [], True

    base = work / "baseline"
    n = snapshot(base)
    rc, fails, log = run_l0(base, {})
    (work / "baseline.log").write_text(log)
    if not keep:
        shutil.rmtree(base)
    print(f"\n==================== BASELINE ({n} files)\n{log}")
    if rc != 0:
        print(f"mutate_l0: BASELINE FAILED (exit {rc}) -- mutants would prove nothing")
        ok_all = False
    rows.append(("base", "-", "unmodified tree", "PASS" if rc == 0 else "FAIL", rc, ",".join(fails) or "-"))

    for mid, want, what, edits, special in MUTANTS:
        root = work / mid
        snapshot(root)
        env = {}
        if special == "fake_verilator":
            fb = work / "fake_bin"
            fb.mkdir(exist_ok=True)
            fv = fb / "verilator"
            fv.write_text(FAKE)
            fv.chmod(0o755)
            env["VERILATOR"] = str(fv)
        else:
            err = None
            for path, old, new, count in edits:
                err = apply(root, path, old, new, count)
                if err:
                    err = f"{path}: {err}"
                    break
            if not edits:
                err = "mutant has no edits"
            if err:
                print(f"\n==================== {mid}: MUTATION NOT APPLIED -- {err}")
                rows.append((mid, want, what, "ERROR", "-", "edit not applied"))
                ok_all = False
                continue
        rc, fails, log = run_l0(root, env)
        (work / f"{mid}.log").write_text(log)
        if not keep:
            shutil.rmtree(root)
        print(f"\n==================== {mid} [{want}] {what}\n{log}")
        caught = rc != 0 and want in fails
        ok_all &= caught
        rows.append((mid, want, what, "CAUGHT" if caught else "MISSED", rc, ",".join(fails) or "-"))

    print("\n==================== MUTATION SUMMARY (L0)")
    print(f"  {'id':<5} {'expected':<16} {'verdict':<7} {'exit':<4} {'checks failed':<34} what")
    for mid, want, what, verdict, rc, fails in rows:
        print(f"  {mid:<5} {want:<16} {verdict:<7} {str(rc):<4} {fails:<34} {what}")
    n_mut = len(MUTANTS)
    n_caught = sum(1 for r in rows if r[3] == "CAUGHT")
    print(f"  {n_caught} of {n_mut} mutants caught; baseline {'PASS' if rows[0][3] == 'PASS' else 'FAIL'}")
    if not keep:
        shutil.rmtree(work)
    else:
        print(f"  copies kept in {work}")
    print("MUTATE_L0: " + ("PASS" if ok_all else "FAIL"))
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
