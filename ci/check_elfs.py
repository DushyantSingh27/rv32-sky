#!/usr/bin/env python3
"""
check_elfs.py -- L0 guard: the committed ACT4 ELF set is exactly the set its
manifest describes, and was exported against the ACT4 configuration that is
in the tree now.

WHY
  The 47 ACT4 ELFs are generated on one machine (riscv-arch-test, GCC 16.1.0,
  Sail) and committed so CI can run them without that toolchain -- the same
  reasoning as the tracked sw/tests/*.hex. A committed binary input can go
  stale silently: the configuration that produced it changes and nothing
  regenerates it. Failure mode #4 one layer up. M3.7, docs/results/0030.

WHAT IS CHECKED (every failure is reported, then exit 1)
  - every file listed in the manifest exists and its sha256 matches
  - no file under the ELF directory is unlisted (the manifest excepted)
  - the number of ELFs equals EXPECT_TOTAL in run_compliance.sh
  - the manifest's exclude list equals EXCLUDE in run_compliance.sh
  - every ACT4 configuration file recorded at export has the same sha256 now
    (link.ld, rv32sky.yaml, test_config.yaml, rvmodel_macros.h, sail.json)
  run_compliance.sh is read, never copied: one source for the count and the
  exclusions.

The manifest is written by verif/compliance/rv32sky/export_elfs.py.

EXIT  0 consistent; 1 mismatch; 2 setup error.
"""

import hashlib
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
COMP = REPO / "verif/compliance/rv32sky"
ELFDIR = COMP / "elfs"
MANIFEST = ELFDIR / "MANIFEST.sha256"
RUNC = COMP / "run_compliance.sh"
HASHLINE = re.compile(r"^([0-9a-f]{64})  (\S+)$")


def setup_error(msg):
    print(f"check_elfs: SETUP ERROR: {msg}")
    sys.exit(2)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_compliance_values():
    if not RUNC.is_file():
        setup_error(f"{RUNC.relative_to(REPO)} not found")
    text = RUNC.read_text()
    tot = re.findall(r"^EXPECT_TOTAL=([0-9]+)$", text, re.M)
    exc = re.findall(r'^EXCLUDE="([^"]*)"$', text, re.M)
    if len(tot) != 1 or len(exc) != 1:
        setup_error(f"run_compliance.sh: found {len(tot)} EXPECT_TOTAL and {len(exc)} EXCLUDE "
                    "assignments, want exactly one of each")
    return int(tot[0]), exc[0]


def read_manifest():
    if not MANIFEST.is_file():
        setup_error(f"{MANIFEST.relative_to(REPO)} not found -- run export_elfs.py")
    meta, configs, files = {}, {}, {}
    for ln, raw in enumerate(MANIFEST.read_text().splitlines(), 1):
        if not raw.strip():
            continue
        if raw.startswith("# config "):
            parts = raw.split()
            if len(parts) != 4 or not re.fullmatch(r"[0-9a-f]{64}", parts[2]):
                setup_error(f"manifest line {ln}: malformed config line")
            configs[parts[3]] = parts[2]
        elif raw.startswith("# ") and ": " in raw:
            k, v = raw[2:].split(": ", 1)
            meta[k.strip()] = v.strip()
        elif raw.startswith("#"):
            continue
        else:
            m = HASHLINE.match(raw)
            if not m:
                setup_error(f"manifest line {ln}: not '<sha256>  <path>': {raw!r}")
            if m.group(2) in files:
                setup_error(f"manifest line {ln}: {m.group(2)} listed twice")
            files[m.group(2)] = m.group(1)
    for k in ("exclude", "expect_total"):
        if k not in meta:
            setup_error(f"manifest has no '{k}' header")
    if not configs:
        setup_error("manifest records no configuration files")
    if not files:
        setup_error("manifest lists no ELFs")
    return meta, configs, files


def main():
    want_total, want_exclude = run_compliance_values()
    meta, configs, files = read_manifest()
    bad = []

    for rel, h in sorted(files.items()):
        p = ELFDIR / rel
        if not p.is_file():
            bad.append(f"listed but missing: {rel}")
        elif sha256(p) != h:
            bad.append(f"sha256 mismatch: {rel}")
    on_disk = {str(p.relative_to(ELFDIR)) for p in ELFDIR.rglob("*") if p.is_file()}
    on_disk.discard(MANIFEST.name)
    for rel in sorted(on_disk - set(files)):
        bad.append(f"on disk but not in the manifest: {rel}")

    if len(files) != want_total:
        bad.append(f"manifest lists {len(files)} ELFs, run_compliance.sh EXPECT_TOTAL={want_total}")
    if meta["expect_total"] != str(want_total):
        bad.append(f"manifest expect_total {meta['expect_total']} != run_compliance.sh {want_total}")
    if meta["exclude"] != want_exclude:
        bad.append(f"manifest exclude '{meta['exclude']}' != run_compliance.sh EXCLUDE '{want_exclude}' "
                   "-- the test set changed; re-export")

    for rel, h in sorted(configs.items()):
        p = REPO / rel
        if not p.is_file():
            bad.append(f"ACT4 config {rel} recorded at export is missing")
        elif sha256(p) != h:
            bad.append(f"ACT4 config {rel} changed since export -- the ELFs may be stale; "
                       "re-run run_compliance.sh and export_elfs.py")

    for k in ("exported", "riscv_arch_test", "compiler", "ref_model"):
        print(f"  {k:<16} {meta.get(k, '(not recorded)')}")
    print(f"check_elfs: {len(files)} ELF(s) listed, {len(on_disk)} on disk, "
          f"{len(configs)} config file(s) bound, EXPECT_TOTAL={want_total}")
    if bad:
        for b in bad:
            print(f"  FAIL  {b}")
        print(f"check_elfs: FAIL ({len(bad)} problem(s))")
        sys.exit(1)
    print("check_elfs: PASS")


if __name__ == "__main__":
    main()
